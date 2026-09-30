//  CFFSubset.swift
//  SwiftTextOpenType
//
//  Builds a standalone CFF-flavoured OpenType font containing only selected
//  glyph outlines. Glyph identifiers are kept: every unused charstring becomes
//  a one-byte `endchar` and every unused subroutine an empty entry, so page
//  streams, widths and the CID-to-glyph mapping need no renumbering. For a
//  CJK face that turns an 11 MB `CFF ` table into a few kilobytes of outlines
//  plus the glyph-indexed offset arrays.

import Foundation

extension OpenTypeFont {
	/// Build a CFF (`CFF ` table) subset for PDF embedding.
	///
	/// `glyphs` maps each used glyph identifier to one representative Unicode
	/// scalar, as for ``subsetTrueType(glyphs:)``. The subset keeps the original
	/// glyph identifiers, so ``OpenTypeSubset/glyphMapping`` is the identity.
	/// A CID-keyed font gets an identity charset, making CID and glyph
	/// identifier the same under every reading of a `CIDFontType0` font.
	///
	/// Returns `nil` for TrueType fonts, `CFF2` (variable) fonts, and charstrings
	/// this subsetter cannot follow (computed subroutine numbers, `seac`-style
	/// accented `endchar`); the caller then embeds the whole face.
	public func subsetCFF(glyphs: [Int: Unicode.Scalar]) throws -> OpenTypeSubset? {
		guard tables["CFF2"] == nil,
		      let cffRecord = tables["CFF "],
		      let headRecord = tables["head"],
		      let hheaRecord = tables["hhea"],
		      let maxpRecord = tables["maxp"],
		      let hmtxRecord = tables["hmtx"] else { return nil }

		let cff = try CFFFont(bytes: tableBytes(cffRecord))
		var used: Set<Int> = [0]
		for glyph in glyphs.keys where glyph >= 0 && glyph < cff.charStrings.count {
			used.insert(glyph)
		}
		guard let subsetTable = try cff.subset(keeping: used) else { return nil }

		var mapping: [Int: Int] = [:]
		for glyph in used { mapping[glyph] = glyph }

		var head = try tableBytes(headRecord)
		Self.replaceUInt32(0, at: 8, in: &head) // checksumAdjustment while checksumming
		var subsetTables: [String: [UInt8]] = [
			"CFF ": subsetTable,
			"cmap": Self.cmap(glyphs: glyphs, mapping: mapping),
			"head": head,
			"hhea": try tableBytes(hheaRecord),
			"hmtx": try tableBytes(hmtxRecord),
			"maxp": try tableBytes(maxpRecord)
		]
		for tag in ["OS/2", "name"] {
			if let record = tables[tag] { subsetTables[tag] = try tableBytes(record) }
		}
		if let postRecord = tables["post"] {
			var post = try tableBytes(postRecord)
			if post.count >= 32 {
				post = Array(post.prefix(32))
				Self.replaceUInt32(0x0003_0000, at: 0, in: &post) // no glyph-name array
				subsetTables["post"] = post
			}
		}
		return OpenTypeSubset(data: Data(Self.sfnt(tables: subsetTables, version: 0x4F54_544F)), glyphMapping: mapping)
	}

	/// This face alone as a standalone sfnt, with every table copied.
	///
	/// A font read from a `.ttc` collection carries the whole collection in
	/// ``data``, which is not a font program a PDF can embed.
	public func standaloneFont() throws -> Data {
		var copied: [String: [UInt8]] = [:]
		for (tag, record) in tables {
			copied[tag] = try tableBytes(record)
		}
		if copied["head"] != nil {
			Self.replaceUInt32(0, at: 8, in: &copied["head"]!)
		}
		let version = tables["CFF "] != nil || tables["CFF2"] != nil ? 0x4F54_544F : 0x0001_0000
		return Data(Self.sfnt(tables: copied, version: version))
	}
}

// MARK: - CFF structures

/// A key/value entry of a CFF DICT, with its operands kept as written.
private struct CFFDictEntry {
	/// The operator; two-byte operators are `0x0C00 | second byte`.
	let op: Int
	/// The operands' encoded bytes, reused verbatim unless rewritten.
	let operandBytes: [UInt8]
	/// Integer operand values (reals are `nil`).
	let operands: [Int?]
}

private enum CFFOperator {
	static let charset = 15
	static let encoding = 16
	static let charStrings = 17
	static let privateDict = 18
	static let subrs = 19
	static let ros = 0x0C1E
	static let fdArray = 0x0C24
	static let fdSelect = 0x0C25
}

/// Thrown while scanning a charstring this subsetter cannot follow; the
/// subset falls back to embedding the whole face.
private struct CFFUnsupported: Error {}

private struct CFFPrivate {
	var entries: [CFFDictEntry]
	var subrs: [ArraySlice<UInt8>]
}

/// A parsed version-1 CFF table.
private struct CFFFont {
	let bytes: [UInt8]
	let header: ArraySlice<UInt8>
	let nameIndex: ArraySlice<UInt8>
	let topDict: [CFFDictEntry]
	let stringIndex: ArraySlice<UInt8>
	let globalSubrs: [ArraySlice<UInt8>]
	let charStrings: [ArraySlice<UInt8>]
	let isCIDKeyed: Bool
	/// A custom name-keyed charset, copied as is (`nil` when predefined).
	let customCharset: ArraySlice<UInt8>?
	/// The raw FDSelect of a CID-keyed font.
	let fdSelect: ArraySlice<UInt8>?
	/// Font DICTs of a CID-keyed font (empty when name-keyed).
	let fontDicts: [[CFFDictEntry]]
	/// One Private DICT per Font DICT, or the single one of a name-keyed font.
	let privates: [CFFPrivate]

	init(bytes: [UInt8]) throws {
		self.bytes = bytes
		let reader = CFFReader(bytes: bytes)
		guard try reader.u8(0) == 1 else { throw OpenTypeError.notSFNT(tag: "CFF ") }
		let headerSize = try reader.u8(2)
		header = try reader.slice(0, headerSize)

		let names = try reader.index(at: headerSize)
		nameIndex = bytes[headerSize ..< names.end]
		let tops = try reader.index(at: names.end)
		guard let topRange = tops.items.first else { throw OpenTypeError.truncated(offset: names.end) }
		let topDict = try reader.dict(topRange)
		self.topDict = topDict
		let strings = try reader.index(at: tops.end)
		stringIndex = bytes[tops.end ..< strings.end]
		let globals = try reader.index(at: strings.end)
		globalSubrs = globals.items.map { bytes[$0] }

		func operand(_ op: Int, _ position: Int = 0) -> Int? {
			guard let entry = topDict.first(where: { $0.op == op }), position < entry.operands.count else { return nil }
			return entry.operands[position]
		}

		guard let charStringsOffset = operand(CFFOperator.charStrings) else {
			throw OpenTypeError.missingTable("CFF CharStrings")
		}
		let charStringIndex = try reader.index(at: charStringsOffset)
		charStrings = charStringIndex.items.map { bytes[$0] }
		let glyphCount = charStrings.count

		isCIDKeyed = topDict.contains { $0.op == CFFOperator.ros }
		if !isCIDKeyed, let charsetOffset = operand(CFFOperator.charset), charsetOffset > 2 {
			customCharset = try reader.slice(charsetOffset, reader.charsetEnd(at: charsetOffset, glyphCount: glyphCount))
		} else {
			customCharset = nil
		}

		if isCIDKeyed {
			guard let fdArrayOffset = operand(CFFOperator.fdArray),
			      let fdSelectOffset = operand(CFFOperator.fdSelect) else {
				throw OpenTypeError.missingTable("CFF FDArray")
			}
			fdSelect = try reader.slice(fdSelectOffset, reader.fdSelectEnd(at: fdSelectOffset, glyphCount: glyphCount))
			let fdArray = try reader.index(at: fdArrayOffset)
			fontDicts = try fdArray.items.map { try reader.dict($0) }
			privates = try fontDicts.map { try reader.privateDict(for: $0) }
		} else {
			fdSelect = nil
			fontDicts = []
			privates = [try reader.privateDict(for: topDict)]
		}
	}

	/// The Font DICT a glyph uses (always 0 for a name-keyed font).
	func fontDictIndex(for glyph: Int) throws -> Int {
		guard let fdSelect else { return 0 }
		let reader = CFFReader(bytes: Array(fdSelect))
		switch try reader.u8(0) {
		case 0:
			return try reader.u8(1 + glyph)
		case 3:
			let rangeCount = try reader.u16(1)
			for range in 0 ..< rangeCount {
				let first = try reader.u16(3 + range * 3)
				let next = try reader.u16(3 + (range + 1) * 3)
				if glyph >= first && glyph < next { return try reader.u8(3 + range * 3 + 2) }
			}
			throw OpenTypeError.truncated(offset: 0)
		default:
			throw CFFUnsupported()
		}
	}

	/// The subset CFF table, or `nil` if a charstring cannot be followed.
	func subset(keeping glyphs: Set<Int>) throws -> [UInt8]? {
		var usedGlobal = Set<Int>()
		var usedLocal = Array(repeating: Set<Int>(), count: privates.count)
		do {
			for glyph in glyphs.sorted() {
				let fontDict = try fontDictIndex(for: glyph)
				guard fontDict < privates.count else { throw CFFUnsupported() }
				var scanner = CharStringScanner(globalSubrs: globalSubrs, localSubrs: privates[fontDict].subrs)
				try scanner.scan(charStrings[glyph])
				usedGlobal.formUnion(scanner.usedGlobal)
				usedLocal[fontDict].formUnion(scanner.usedLocal)
			}
		} catch is CFFUnsupported {
			return nil
		}

		let endchar: ArraySlice<UInt8> = [14]
		let newCharStrings = charStrings.indices.map { glyphs.contains($0) ? charStrings[$0] : endchar }
		let newGlobalSubrs = globalSubrs.indices.map { usedGlobal.contains($0) ? globalSubrs[$0] : [] }

		// Every offset operand is written as a five-byte integer, so DICT sizes
		// are known before the offsets they hold.
		let charset = isCIDKeyed ? Self.identityCharset(glyphCount: charStrings.count) : customCharset.map(Array.init)
		let privateBlocks: [(dict: [CFFDictEntry], subrs: [UInt8])] = privates.indices.map { index in
			let subrs = privates[index].subrs.indices.map { usedLocal[index].contains($0) ? privates[index].subrs[$0] : [] }
			return (privates[index].entries, subrs.isEmpty ? [] : CFFWriter.index(subrs))
		}
		let privateSizes = privateBlocks.map { block in
			CFFWriter.dict(block.dict, replacing: [CFFOperator.subrs: [0]]).count
		}

		let topEntries = topDict.filter { $0.op != CFFOperator.encoding } // unused under CID addressing
		func topDictBytes(_ offsets: [Int: [Int]]) -> [UInt8] {
			CFFWriter.index([ArraySlice(CFFWriter.dict(topEntries, replacing: offsets, adding: charset == nil ? [] : [CFFOperator.charset]))])
		}
		// The same operators as the final `offsets` below, so the sizes match.
		var placeholders: [Int: [Int]] = [CFFOperator.charStrings: [0]]
		if charset != nil { placeholders[CFFOperator.charset] = [0] }
		if isCIDKeyed {
			placeholders[CFFOperator.fdSelect] = [0]
			placeholders[CFFOperator.fdArray] = [0]
		} else {
			placeholders[CFFOperator.privateDict] = [0, 0]
		}
		let topSize = topDictBytes(placeholders).count
		let globalSubrIndex = CFFWriter.index(newGlobalSubrs)
		let charStringIndex = CFFWriter.index(newCharStrings)

		var cursor = header.count + nameIndex.count + topSize + stringIndex.count + globalSubrIndex.count
		var offsets: [Int: [Int]] = [:]
		if let charset {
			offsets[CFFOperator.charset] = [cursor]
			cursor += charset.count
		}
		if let fdSelect {
			offsets[CFFOperator.fdSelect] = [cursor]
			cursor += fdSelect.count
		}
		offsets[CFFOperator.charStrings] = [cursor]
		cursor += charStringIndex.count

		var fdArrayIndex: [UInt8] = []
		var privateStart = cursor
		if isCIDKeyed {
			let placeholderIndex = CFFWriter.index(fontDicts.map {
				ArraySlice(CFFWriter.dict($0, replacing: [CFFOperator.privateDict: [0, 0]]))
			})
			offsets[CFFOperator.fdArray] = [cursor]
			privateStart = cursor + placeholderIndex.count
			var privateOffset = privateStart
			var fontDictBytes: [ArraySlice<UInt8>] = []
			for (index, dict) in fontDicts.enumerated() {
				fontDictBytes.append(ArraySlice(CFFWriter.dict(dict, replacing: [CFFOperator.privateDict: [privateSizes[index], privateOffset]])))
				privateOffset += privateSizes[index] + privateBlocks[index].subrs.count
			}
			fdArrayIndex = CFFWriter.index(fontDictBytes)
		} else {
			offsets[CFFOperator.privateDict] = [privateSizes[0], privateStart]
		}

		var output = Array(header) + Array(nameIndex) + topDictBytes(offsets) + Array(stringIndex) + globalSubrIndex
		if let charset { output += charset }
		if let fdSelect { output += fdSelect }
		output += charStringIndex
		output += fdArrayIndex
		for (index, block) in privateBlocks.enumerated() {
			let hasSubrs = block.dict.contains { $0.op == CFFOperator.subrs }
			output += CFFWriter.dict(block.dict, replacing: hasSubrs ? [CFFOperator.subrs: [privateSizes[index]]] : [:])
			output += block.subrs
		}
		return output
	}

	/// Format 2 charset mapping glyph `n` to CID `n`.
	private static func identityCharset(glyphCount: Int) -> [UInt8] {
		guard glyphCount > 1 else { return [0] }
		let remaining = glyphCount - 2
		return [2, 0, 1, UInt8((remaining >> 8) & 0xFF), UInt8(remaining & 0xFF)]
	}
}

// MARK: - Reading

private struct CFFReader {
	let bytes: [UInt8]

	func u8(_ offset: Int) throws -> Int {
		guard offset >= 0, offset < bytes.count else { throw OpenTypeError.truncated(offset: offset) }
		return Int(bytes[offset])
	}

	func u16(_ offset: Int) throws -> Int {
		try u8(offset) << 8 | u8(offset + 1)
	}

	/// `bytes[lower ..< upper]`, throwing instead of trapping when a font's
	/// offsets or sizes point outside the table.
	func slice(_ lower: Int, _ upper: Int) throws -> ArraySlice<UInt8> {
		guard lower >= 0, upper >= lower, upper <= bytes.count else {
			throw OpenTypeError.truncated(offset: max(lower, upper))
		}
		return bytes[lower ..< upper]
	}

	func offset(_ position: Int, size: Int) throws -> Int {
		var value = 0
		for index in 0 ..< size { value = value << 8 | (try u8(position + index)) }
		return value
	}

	/// The item ranges of the INDEX at `position`, and where it ends.
	func index(at position: Int) throws -> (items: [Range<Int>], end: Int) {
		let count = try u16(position)
		guard count > 0 else { return ([], position + 2) }
		let offSize = try u8(position + 2)
		guard (1 ... 4).contains(offSize) else { throw OpenTypeError.truncated(offset: position + 2) }
		let dataStart = position + 3 + (count + 1) * offSize - 1
		var items: [Range<Int>] = []
		items.reserveCapacity(count)
		var previous = try offset(position + 3, size: offSize)
		for item in 1 ... count {
			let next = try offset(position + 3 + item * offSize, size: offSize)
			guard previous >= 1, next >= previous, dataStart + next <= bytes.count else {
				throw OpenTypeError.truncated(offset: dataStart + next)
			}
			items.append(dataStart + previous ..< dataStart + next)
			previous = next
		}
		return (items, dataStart + previous)
	}

	func dict(_ range: Range<Int>) throws -> [CFFDictEntry] {
		guard range.upperBound <= bytes.count else { throw OpenTypeError.truncated(offset: range.upperBound) }
		var entries: [CFFDictEntry] = []
		var operandStart = range.lowerBound
		var operands: [Int?] = []
		var cursor = range.lowerBound
		while cursor < range.upperBound {
			let byte = try u8(cursor)
			switch byte {
			case 0 ... 21:
				var op = byte
				var length = 1
				if byte == 12 {
					op = 0x0C00 | (try u8(cursor + 1))
					length = 2
				}
				entries.append(CFFDictEntry(op: op, operandBytes: Array(bytes[operandStart ..< cursor]), operands: operands))
				cursor += length
				operandStart = cursor
				operands = []
			case 28:
				let value = try u16(cursor + 1)
				operands.append(value >= 0x8000 ? value - 0x10000 : value)
				cursor += 3
			case 29:
				let value = try offset(cursor + 1, size: 4)
				operands.append(value >= 0x8000_0000 ? value - 0x1_0000_0000 : value)
				cursor += 5
			case 30:
				cursor += 1
				while true {
					let nibbles = try u8(cursor)
					cursor += 1
					if nibbles & 0x0F == 0x0F || nibbles >> 4 == 0x0F { break }
				}
				operands.append(nil)
			case 32 ... 246:
				operands.append(byte - 139)
				cursor += 1
			case 247 ... 250:
				operands.append((byte - 247) * 256 + (try u8(cursor + 1)) + 108)
				cursor += 2
			case 251 ... 254:
				operands.append(-(byte - 251) * 256 - (try u8(cursor + 1)) - 108)
				cursor += 2
			default:
				throw OpenTypeError.truncated(offset: cursor)
			}
		}
		return entries
	}

	/// The Private DICT (and its local subroutines) a Top or Font DICT names.
	func privateDict(for dict: [CFFDictEntry]) throws -> CFFPrivate {
		guard let entry = dict.first(where: { $0.op == CFFOperator.privateDict }),
		      entry.operands.count == 2,
		      let size = entry.operands[0], let offset = entry.operands[1] else {
			return CFFPrivate(entries: [], subrs: [])
		}
		let entries = try self.dict(slice(offset, offset + size).indices)
		var subrs: [ArraySlice<UInt8>] = []
		if let subrsEntry = entries.first(where: { $0.op == CFFOperator.subrs }),
		   let relative = subrsEntry.operands.first ?? nil {
			subrs = try index(at: offset + relative).items.map { bytes[$0] }
		}
		return CFFPrivate(entries: entries, subrs: subrs)
	}

	func charsetEnd(at position: Int, glyphCount: Int) throws -> Int {
		var covered = 1 // .notdef is implicit
		var cursor = position + 1
		switch try u8(position) {
		case 0:
			return position + 1 + (glyphCount - 1) * 2
		case 1, 2:
			let countSize = try u8(position) == 1 ? 1 : 2
			while covered < glyphCount {
				covered += (try offset(cursor + 2, size: countSize)) + 1
				cursor += 2 + countSize
			}
			return cursor
		default:
			throw CFFUnsupported()
		}
	}

	func fdSelectEnd(at position: Int, glyphCount: Int) throws -> Int {
		switch try u8(position) {
		case 0: return position + 1 + glyphCount
		case 3: return position + 3 + (try u16(position + 1)) * 3 + 2
		default: throw CFFUnsupported()
		}
	}
}

// MARK: - Charstring scanning

/// Walks Type 2 charstrings to find the subroutines a glyph calls.
///
/// Only numbers, stem hints (for the length of `hintmask` data) and the two
/// call operators matter; every other operator just clears the stack.
private struct CharStringScanner {
	let globalSubrs: [ArraySlice<UInt8>]
	let localSubrs: [ArraySlice<UInt8>]
	private(set) var usedGlobal = Set<Int>()
	private(set) var usedLocal = Set<Int>()
	private var stack: [Int?] = []
	private var stemCount = 0
	private var finished = false

	init(globalSubrs: [ArraySlice<UInt8>], localSubrs: [ArraySlice<UInt8>]) {
		self.globalSubrs = globalSubrs
		self.localSubrs = localSubrs
	}

	mutating func scan(_ charString: ArraySlice<UInt8>) throws {
		try run(charString, depth: 0)
	}

	private static func bias(_ count: Int) -> Int {
		count < 1240 ? 107 : count < 33900 ? 1131 : 32768
	}

	private mutating func run(_ code: ArraySlice<UInt8>, depth: Int) throws {
		guard depth <= 10 else { throw CFFUnsupported() } // Type 2 nesting limit
		var cursor = code.startIndex
		func byte(_ offset: Int) throws -> Int {
			guard offset < code.endIndex else { throw CFFUnsupported() }
			return Int(code[offset])
		}
		while cursor < code.endIndex, !finished {
			let op = Int(code[cursor])
			switch op {
			case 28:
				let value = (try byte(cursor + 1)) << 8 | (try byte(cursor + 2))
				stack.append(value >= 0x8000 ? value - 0x10000 : value)
				cursor += 3
			case 32 ... 246:
				stack.append(op - 139)
				cursor += 1
			case 247 ... 250:
				stack.append((op - 247) * 256 + (try byte(cursor + 1)) + 108)
				cursor += 2
			case 251 ... 254:
				stack.append(-(op - 251) * 256 - (try byte(cursor + 1)) - 108)
				cursor += 2
			case 255:
				var fixed = 0
				for index in 1 ... 4 { fixed = fixed << 8 | (try byte(cursor + index)) }
				stack.append(fixed & 0xFFFF == 0 ? Int(Int32(truncatingIfNeeded: fixed)) >> 16 : nil)
				cursor += 5
			case 1, 3, 18, 23: // hstem, vstem, hstemhm, vstemhm
				stemCount += stack.count / 2
				stack.removeAll()
				cursor += 1
			case 19, 20: // hintmask, cntrmask: a pending vstem list is implicit
				stemCount += stack.count / 2
				stack.removeAll()
				cursor += 1 + (stemCount + 7) / 8
			case 10, 29: // callsubr, callgsubr
				guard let number = stack.popLast() ?? nil else { throw CFFUnsupported() }
				let subrs = op == 10 ? localSubrs : globalSubrs
				let index = number + Self.bias(subrs.count)
				guard subrs.indices.contains(index) else { throw CFFUnsupported() }
				if op == 10 { usedLocal.insert(index) } else { usedGlobal.insert(index) }
				cursor += 1
				try run(subrs[index], depth: depth + 1)
			case 11: // return
				return
			case 14: // endchar; four more operands would be a seac accent
				if stack.count >= 4 { throw CFFUnsupported() }
				finished = true
				return
			case 12:
				stack.removeAll()
				cursor += 2
			default:
				stack.removeAll()
				cursor += 1
			}
		}
	}
}

// MARK: - Writing

private enum CFFWriter {
	static func index(_ items: [ArraySlice<UInt8>]) -> [UInt8] {
		guard !items.isEmpty else { return [0, 0] }
		let total = items.reduce(0) { $0 + $1.count } + 1
		let offSize = total <= 0xFF ? 1 : total <= 0xFFFF ? 2 : total <= 0xFF_FFFF ? 3 : 4
		var output: [UInt8] = [UInt8(items.count >> 8), UInt8(items.count & 0xFF), UInt8(offSize)]
		output.reserveCapacity(3 + (items.count + 1) * offSize + total)
		var offset = 1
		func appendOffset(_ value: Int) {
			for shift in stride(from: (offSize - 1) * 8, through: 0, by: -8) {
				output.append(UInt8((value >> shift) & 0xFF))
			}
		}
		appendOffset(offset)
		for item in items {
			offset += item.count
			appendOffset(offset)
		}
		for item in items { output += item }
		return output
	}

	/// Encode `entries`, replacing the operands of the operators in
	/// `replacing` with five-byte integers, and appending `adding` operators
	/// (taking their operands from `replacing`) when absent.
	static func dict(_ entries: [CFFDictEntry], replacing: [Int: [Int]], adding: [Int] = []) -> [UInt8] {
		var output: [UInt8] = []
		func appendOperator(_ op: Int) {
			if op >= 0x0C00 {
				output += [12, UInt8(op & 0xFF)]
			} else {
				output.append(UInt8(op))
			}
		}
		func appendIntegers(_ values: [Int]) {
			for value in values {
				let bits = UInt32(truncatingIfNeeded: value)
				output += [29, UInt8(bits >> 24), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8(bits & 0xFF)]
			}
		}
		// ROS must stay first in a CID-keyed Top DICT.
		for entry in entries {
			if let values = replacing[entry.op] {
				appendIntegers(values)
			} else {
				output += entry.operandBytes
			}
			appendOperator(entry.op)
		}
		for op in adding where !entries.contains(where: { $0.op == op }) {
			appendIntegers(replacing[op] ?? [0])
			appendOperator(op)
		}
		return output
	}
}
