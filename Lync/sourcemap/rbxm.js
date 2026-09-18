const LZ4 = require("lz4js")
const ZSTD = require('fzstd')

const UTF8 = new TextDecoder('utf-8')

/** @type {Buffer} */
let buf;
/** @type {number} */
let start;

/**
 * @param {number} bytes
 * @returns {Buffer | Uint8Array}
 */
function readBytes(bytes) {
	const read = buf.subarray(start, start + bytes)
	start += bytes
	return read
}

/**
 * @param {number} bytes
 * @returns {string}
 */
function readUTF8(bytes) {
	const read = buf.subarray(start, start + bytes)
	start += bytes
	return UTF8.decode(read)
}

/**
 * @returns {number}
 */
function readUInt32LE() {
	const read = buf.readUInt32LE(start)
	start += 4
	return read
}

/**
 * Referent arrays are stored as byte-interleaved, zigzag-transformed, delta-encoded big-endian i32s.
 * @param {number} length
 * @returns {number[]}
 */
function readReferentArray(length) {
	const arr = readBytes(length * 4)
	const output = new Array(length)
	let referent = 0
	for (let i = 0; i < length; i++) {
		const transformed = ((arr[i] << 24) | (arr[i + length] << 16) | (arr[i + length * 2] << 8) | arr[i + length * 3]) >>> 0
		referent += (transformed >>> 1) ^ -(transformed & 1)
		output[i] = referent
	}
	return output
}

/**
 * @param {any} target
 * @param {Map<number, any>} instances
 * @param {any} rbxm
 */
function recurse(target, instances, rbxm) {
	target.className = rbxm.className

	for (const childReferent of rbxm.children) {
		let nextTarget = target
		const rbxmChild = instances.get(childReferent)
		const name = rbxmChild.name
		const className = rbxmChild.className

		// Map under existing child
		let hasChild = false
		for (const child of nextTarget.children) {
			if (child.name == name) {
				nextTarget = child
				hasChild = true
				break
			}
		}

		// Add new child
		if (!hasChild) {
			nextTarget = nextTarget.children[nextTarget.children.push({
				'name': name,
				'className': className,
				'filePaths': [],
				'children': []
			}) - 1]
		}

		recurse(nextTarget, instances, rbxmChild)
	}
}

/**
 * @param {any} target
 * @param {Buffer} fileRead
 */
module.exports.fill = function(target, fileRead) {
	/** Referent -> instance */
	const instances = new Map()
	/** Class ID -> instances in INST-chunk order, which is the order PROP chunks list their values in */
	const classInstances = new Map()

	buf = fileRead
	start = 0

	start += 32 // header
	while (start < fileRead.length) {
		const chunkName = readUTF8(4)
		const compressedLength = readUInt32LE()
		const uncompressedLength = readUInt32LE()
		start += 4 // reserved

		let chunkData;
		if (compressedLength == 0) {
			chunkData = readBytes(uncompressedLength)
		} else {
			const magicNumber = buf.subarray(start, start + 4)
			if (magicNumber.equals(Buffer.from([ 0x28, 0xb5, 0x2f, 0xfd ]))) {
				chunkData = Buffer.from(ZSTD.decompress(readBytes(compressedLength)))
			} else {
				chunkData = Buffer.alloc(uncompressedLength)
				LZ4.decompressBlock(readBytes(compressedLength), chunkData, 0, compressedLength, 0)
			}
		}

		const prevStart = start
		buf = chunkData
		start = 0

		if (chunkName == 'INST') {
			const classId = readUInt32LE()
			const classNameLength = readUInt32LE()
			const className = readUTF8(classNameLength)
			start += 1 // objectFormat
			const instanceCount = readUInt32LE()
			const referents = readReferentArray(instanceCount)
			const list = classInstances.get(classId) ?? []
			for (const referent of referents) {
				const instance = {
					classId: classId,
					className: className,
					name: '',
					parent: -1,
					children: []
				}
				instances.set(referent, instance)
				list.push(instance)
			}
			if (!classInstances.has(classId)) classInstances.set(classId, list)
		} else if (chunkName == 'PROP') {
			const classId = readUInt32LE()
			const propertyNameLength = readUInt32LE()
			const propertyName = readUTF8(propertyNameLength)
			start += 1 // typeId
			if (propertyName == 'Name') {
				for (const instance of classInstances.get(classId) ?? []) {
					const stringLength = readUInt32LE()
					instance.name = readUTF8(stringLength)
				}
			}
		} else if (chunkName == 'PRNT') {
			start += 1 // version
			const instanceCount = readUInt32LE()
			const childReferents = readReferentArray(instanceCount)
			const parentReferents = readReferentArray(instanceCount)
			for (let index = 0; index < instanceCount; index++) {
				instances.get(childReferents[index]).parent = parentReferents[index]
				if (parentReferents[index] >= 0)
					instances.get(parentReferents[index]).children.push(childReferents[index])
			}
		}

		buf = fileRead
		start = prevStart
	}

	for (const instance of instances.values()) {
		if (instance.parent == -1) {
			recurse(target, instances, instance)
			break
		}
	}
}
