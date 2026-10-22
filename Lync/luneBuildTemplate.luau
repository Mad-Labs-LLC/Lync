--!nocheck
--[[
	Lync Build Template
	https://github.com/Iron-Stag-Games/Lync
	Copyright (C) 2025  Iron Stag Games

	This library is free software; you can redistribute it and/or
	modify it under the terms of the GNU Lesser General Public
	License as published by the Free Software Foundation; either
	version 2.1 of the License, or (at your option) any later version.

	This library is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
	Lesser General Public License for more details.

	You should have received a copy of the GNU Lesser General Public
	License along with this library; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301
	USA
]]

-- `lync build` turns this template into a Lune script: the plugin's build functions (everything between the --offline markers in
-- RobloxPluginSource/Plugin.luau) replace the plugin-source marker line in the "Build functions" section below. Lune then runs them
-- against a blank DataModel while the Lync server answers Source requests over HTTP, so a build walks the same path as a Studio sync,
-- and the result is serialized with the same rbx-dom serializer Rojo uses. Everything above the marker stands in for the Studio APIs
-- those functions expect.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local net = require("@lune/net")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local Enum = roblox.Enum
local Instance = roblox.Instance

-- Written by the Lync server: { Port: number, Output: string, Map: table }
local BUILD = serde.decode("json", fs.readFile(process.args[1]))

local game = Instance.new("DataModel")
local workspace = game:GetService("Workspace")

local SUPPRESSED_CLASSES = {
	"Terrain";
	"StarterCharacterScripts";
	"StarterPlayerScripts";
	"ChatWindowConfiguration";
	"ChatInputBarConfiguration";
	"BubbleChatConfiguration";
}
local TERRAIN_MIN_CORNER = roblox.Vector3int16.new(-32000, -32000, -32000)
local EMPTY_SMOOTH_GRID = Instance.new("Terrain").SmoothGrid

local serverKey = "BuildScript"
local map = BUILD.Map
local activeSourceRequests = 0
local changedFiles = {}
local scheduledAfterSync = {}
local errorCount = 0
local warningCount = 0

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Lune appends a stack trace of this generated script to runtime errors; only the first line means anything to the project author
local function stripPrefix(message: any): string
	local firstLine = tostring(message):match("^([^\n]*)") or ""
	return (firstLine:gsub("^%[Lync%] %- ", ""):gsub("runtime error: ", "", 1))
end

local function logError(message: any)
	errorCount += 1
	stdio.ewrite(stdio.color("red") .. "Build error: " .. stdio.color("reset") .. stripPrefix(message) .. "\n")
end

local function logWarning(message: any)
	warningCount += 1
	stdio.ewrite(stdio.color("yellow") .. "Build warning: " .. stdio.color("reset") .. stripPrefix(message) .. "\n")
end

local function unsupported(what: string)
	logWarning(what .. " cannot be applied by Lune, so this build skipped it")
end

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Studio stand-ins
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- The plugin spawns a thread per file so one failure cannot stop the sync; here each spawn runs to completion and failures are counted
local task = {
	spawn = function(func, ...)
		if func == error then
			logError((...))
			return
		end
		local success, result = pcall(func, ...)
		if not success then
			logError(result)
		end
	end;
	wait = function() end;
}

local function terminate(errorMessage: string)
	error("[Lync] - " .. errorMessage, 0)
end

local function lpcall(context: string, warning: boolean, func: any, ...): (boolean, any)
	local args = {...}
	return xpcall(function()
		return func(unpack(args))
	end, function(err: any)
		if warning then
			logWarning(context .. ": " .. tostring(err))
		else
			logError(context .. ": " .. tostring(err))
		end
	end)
end

local HttpService = {
	GetAsync = function(_, url: string, _nocache: boolean, headers: {[string]: string}): string
		local response = net.request({
			url = url,
			method = "GET",
			headers = headers,
		})
		if not response.ok then
			error(`HTTP {response.statusCode}: {response.body}`, 0)
		end
		return response.body
	end;
	JSONDecode = function(_, json: string): any
		return serde.decode("json", json)
	end;
}

local CollectionService = {
	AddTag = function(_, instance, tag: string)
		instance:AddTag(tag)
	end;
}

-- Lune cannot register collision groups (Workspace.CollisionGroupData is opaque to it), so pretend every group exists and say so once
local collisionGroupsWarned = false
local PhysicsService = {
	IsCollisionGroupRegistered = function(): boolean
		if not collisionGroupsWarned then
			collisionGroupsWarned = true
			unsupported(`Collision groups ({map.info.CollisionGroupsFile})`)
		end
		return true
	end;
	RegisterCollisionGroup = function() end;
	CollisionGroupSetCollidable = function() end;
}

-- `eval` validates property strings against a strict grammar before they get here; this environment is what they can name
local LOADSTRING_ENVIRONMENT = {
	game = game;
	workspace = workspace;
	InstanceHandle = {
		new = function()
			unsupported("InstanceHandle")
			return nil
		end;
	};
}
for _, typeName in {
	"Instance", "Axes", "BrickColor", "CFrame", "Color3", "ColorSequence", "ColorSequenceKeypoint", "Enum", "Faces", "Font",
	"NumberRange", "NumberSequence", "NumberSequenceKeypoint", "PhysicalProperties", "Ray", "Rect", "Region3", "Region3int16",
	"UDim", "UDim2", "Vector2", "Vector2int16", "Vector3", "Vector3int16",
} do
	LOADSTRING_ENVIRONMENT[typeName] = roblox[typeName]
end

local function loadstring(code: string)
	return luau.load(code, { debugName = "property", environment = LOADSTRING_ENVIRONMENT })
end

local function deserialize(path: string, data: string): {Instance}?
	local success, result = lpcall(`Deserialize "{path}"`, false, roblox.deserializeModel, data)
	return if success then result else nil
end

local function getHost(): string
	return "http://127.0.0.1:" .. BUILD.Port
end

local function setScriptSourceLive(container, lua: string)
	container.Source = (lua:gsub("\r", ""))
end

local function updateChangedFilesUI() end

local function listenForChanges(_target, _data) end

-- Instance methods the build functions call that Lune does not implement

roblox.implementMethod("Terrain", "Clear", function(terrain)
	terrain.SmoothGrid = EMPTY_SMOOTH_GRID
end)

-- A TerrainRegion saved from Terrain.MaxExtents pastes back exactly by copying its voxel grid; any other corner would need a re-encode
roblox.implementMethod("Terrain", "PasteRegion", function(terrain, region, corner, _pasteEmptyCells)
	if corner ~= TERRAIN_MIN_CORNER then
		logWarning(`Terrain:PasteRegion can only paste at {TERRAIN_MIN_CORNER} in a build; the region was pasted there instead of at {corner}`)
	end
	terrain.SmoothGrid = region.SmoothGrid
end)

-- Studio stores a LocalizationTable's entries in its Contents property as JSON; this writes the same shape Rojo writes for csv files
roblox.implementMethod("LocalizationTable", "SetEntries", function(localizationTable, entries)
	local jsonEntries = {}
	for _, entry in entries do
		local jsonValues = {}
		for locale, text in entry.Values or {} do
			table.insert(jsonValues, serde.encode("json", tostring(locale)) .. ":" .. serde.encode("json", tostring(text)))
		end
		table.insert(jsonEntries,
			'{"key":' .. serde.encode("json", tostring(entry.Key or ""))
			.. ',"source":' .. serde.encode("json", tostring(entry.Source or ""))
			.. ',"context":' .. serde.encode("json", tostring(entry.Context or ""))
			.. ',"example":' .. serde.encode("json", tostring(entry.Example or ""))
			.. ',"values":{' .. table.concat(jsonValues, ",") .. "}}"
		)
	end
	localizationTable.Contents = "[" .. table.concat(jsonEntries, ",") .. "]"
end)

roblox.implementMethod("Model", "ScaleTo", function(model, scale)
	unsupported(`Model:ScaleTo({scale}) on {model:GetFullName()}`)
end)

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Build functions (copied from the plugin by the Lync server)
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

--lync-plugin-source

--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

do
	local success, result = pcall(buildAll)
	if not success then
		logError(result)
		stdio.ewrite(stdio.color("red") .. "Build aborted; no file was written" .. stdio.color("reset") .. "\n")
		process.exit(1)
	end
end

for _, scheduled in scheduledAfterSync do
	task.spawn(scheduled.Func, unpack(scheduled.Args))
end
table.clear(scheduledAfterSync)

-- Studio would otherwise create a second camera next to the one the project built
local camera = workspace:FindFirstChildOfClass("Camera")
if camera then
	pcall(function()
		workspace.CurrentCamera = camera
	end)
end

-- Serialize; the Lync server already checked the extension
local extension = BUILD.Output:match("%.([^.\\/]+)$"):lower()
local xml = extension == "rbxlx" or extension == "rbxmx"
local contents
if extension == "rbxl" or extension == "rbxlx" then
	contents = roblox.serializePlace(game, xml)
else
	-- Model files hold each service the project maps as a root Instance, the same layout Studio writes when saving a service to file
	local roots = {}
	for _, service in game:GetChildren() do
		if map.tree["tree/" .. service.ClassName] then
			table.insert(roots, service)
		end
	end
	contents = roblox.serializeModel(roots, xml)
end
fs.writeFile(BUILD.Output, contents)

if errorCount > 0 then
	stdio.ewrite(stdio.color("red") .. `Build saved with {errorCount} error(s)` .. stdio.color("reset") .. "\n")
	process.exit(1)
elseif warningCount > 0 then
	stdio.ewrite(stdio.color("yellow") .. `Build saved with {warningCount} warning(s)` .. stdio.color("reset") .. "\n")
end
