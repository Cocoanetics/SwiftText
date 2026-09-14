//  TrueTypeSubset.swift
//  SwiftTextOpenType
//
//  Builds a standalone sfnt containing only selected TrueType glyphs. Composite
//  dependencies are retained and rewritten to dense glyph identifiers.

import Foundation

/// A subset TrueType font and the original-to-subset glyph identifier mapping.
public struct OpenTypeSubset {
	public let data: Data
	public let glyphMapping: [Int: Int]
}

extension OpenTypeFont {
	/// Build a dense TrueType (`glyf`/`loca`) subset for PDF embedding.
	///
	/// `glyphs` maps each used original glyph identifier to one representative
	/// Unicode scalar. The scalar mapping is written into the subset's `cmap`;
	/// composite component glyphs are included automatically.
	///
	/// Returns `nil` for CFF-flavoured OpenType fonts, whose outline format needs
	/// a different subsetter.
	public func subsetTrueType(glyphs: [Int: Unicode.Scalar]) throws -> OpenTypeSubset? {
		guard !hasCFFOutlines,
		      let glyfRecord = tables["glyf"],
		      let locaRecord = tables["loca"],
		      let headRecord = tables["head"],
		      let hheaRecord = tables["hhea"],
		      let maxpRecord = tables["maxp"] else { return nil }

		let locaFormat = try fonts.i16(headRecord.offset + 50)
		guard locaFormat == 0 || locaFormat == 1 else {
			throw OpenTypeError.truncated(offset: headRecord.offset + 50)
		}
		let locaEntrySize = locaFormat == 0 ? 2 : 4
		guard locaRecord.length >= (numGlyphs + 1) * locaEntrySize else {
			throw OpenTypeError.truncated(offset: locaRecord.offset + locaRecord.length)
		}

		func glyphRange(_ glyph: Int) throws -> Range<Int> {
			guard glyph >= 0, glyph < numGlyphs else {
				throw OpenTypeError.truncated(offset: locaRecord.offset)
			}
			let first: Int
			let last: Int
			if locaFormat == 0 {
				first = try fonts.u16(locaRecord.offset + glyph * 2) * 2
				last = try fonts.u16(locaRecord.offset + (glyph + 1) * 2) * 2
			} else {
				first = try fonts.u32(locaRecord.offset + glyph * 4)
				last = try fonts.u32(locaRecord.offset + (glyph + 1) * 4)
			}
			guard first >= 0, last >= first, last <= glyfRecord.length else {
				throw OpenTypeError.truncated(offset: glyfRecord.offset + last)
			}
			return glyfRecord.offset + first ..< glyfRecord.offset + last
		}

		/// Component glyph identifiers and their offsets within a composite glyph.
		func components(of glyph: Int) throws -> [(glyph: Int, offset: Int)] {
			let range = try glyphRange(glyph)
			guard range.count >= 10 else { return [] } // empty glyph
			guard try fonts.i16(range.lowerBound) < 0 else { return [] }
			var cursor = range.lowerBound + 10
			var result: [(glyph: Int, offset: Int)] = []
			var more = true
			while more {
				guard cursor + 4 <= range.upperBound else {
					throw OpenTypeError.truncated(offset: cursor)
				}
				let flags = try fonts.u16(cursor)
				let component = try fonts.u16(cursor + 2)
				guard component < numGlyphs else {
					throw OpenTypeError.truncated(offset: cursor + 2)
				}
				result.append((component, cursor + 2 - range.lowerBound))
				cursor += 4
				cursor += (flags & 0x0001) != 0 ? 4 : 2 // component arguments
				if (flags & 0x0008) != 0 {
					cursor += 2
				} else if (flags & 0x0040) != 0 {
					cursor += 4
				} else if (flags & 0x0080) != 0 {
					cursor += 8
				}
				guard cursor <= range.upperBound else {
					throw OpenTypeError.truncated(offset: cursor)
				}
				more = (flags & 0x0020) != 0
			}
			return result
		}

		var included: Set<Int> = [0]
		for glyph in glyphs.keys {
			guard glyph >= 0, glyph < numGlyphs else { continue }
			included.insert(glyph)
		}
		var pending = included.sorted()
		var pendingIndex = 0
		while pendingIndex < pending.count {
			for component in try components(of: pending[pendingIndex]) where included.insert(component.glyph).inserted {
				pending.append(component.glyph)
			}
			pendingIndex += 1
		}

		let orderedGlyphs = [0] + included.filter { $0 != 0 }.sorted()
		var mapping: [Int: Int] = [:]
		for (newGlyph, oldGlyph) in orderedGlyphs.enumerated() {
			mapping[oldGlyph] = newGlyph
		}

		var glyf: [UInt8] = []
		var loca: [UInt8] = []
		for oldGlyph in orderedGlyphs {
			Self.appendUInt32(glyf.count, to: &loca)
			let range = try glyphRange(oldGlyph)
			var bytes = Array(fonts.bytes[range])
			for component in try components(of: oldGlyph) {
				guard let newGlyph = mapping[component.glyph] else { continue }
				Self.replaceUInt16(newGlyph, at: component.offset, in: &bytes)
			}
			glyf += bytes
			while glyf.count % 4 != 0 { glyf.append(0) }
		}
		Self.appendUInt32(glyf.count, to: &loca)

		var hmtx: [UInt8] = []
		for oldGlyph in orderedGlyphs {
			let metricIndex = min(oldGlyph, numberOfHMetrics - 1)
			let advance = try fonts.u16(hmtxOffset + metricIndex * 4)
			let lsbOffset = oldGlyph < numberOfHMetrics
				? hmtxOffset + oldGlyph * 4 + 2
				: hmtxOffset + numberOfHMetrics * 4 + (oldGlyph - numberOfHMetrics) * 2
			let sideBearing = try fonts.u16(lsbOffset)
			Self.appendUInt16(advance, to: &hmtx)
			Self.appendUInt16(sideBearing, to: &hmtx)
		}

		var head = try tableBytes(headRecord)
		Self.replaceUInt32(0, at: 8, in: &head) // checksumAdjustment while checksumming
		Self.replaceUInt16(1, at: 50, in: &head) // long loca offsets
		var hhea = try tableBytes(hheaRecord)
		Self.replaceUInt16(orderedGlyphs.count, at: 34, in: &hhea)
		var maxp = try tableBytes(maxpRecord)
		Self.replaceUInt16(orderedGlyphs.count, at: 4, in: &maxp)

		var subsetTables: [String: [UInt8]] = [
			"cmap": Self.cmap(glyphs: glyphs, mapping: mapping),
			"glyf": glyf,
			"head": head,
			"hhea": hhea,
			"hmtx": hmtx,
			"loca": loca,
			"maxp": maxp
		]
		// Keep only tables that do not carry glyph-indexed arrays. Hinting programs
		// remain useful, while shaping tables from the original glyph order would
		// make the subset internally inconsistent.
		for tag in ["OS/2", "cvt ", "fpgm", "gasp", "name", "prep"] {
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

		return OpenTypeSubset(data: Data(Self.sfnt(tables: subsetTables)), glyphMapping: mapping)
	}

	private func tableBytes(_ record: (offset: Int, length: Int)) throws -> [UInt8] {
		guard record.offset >= 0, record.length >= 0,
		      record.offset + record.length <= fonts.count else {
			throw OpenTypeError.truncated(offset: record.offset)
		}
		return Array(fonts.bytes[record.offset ..< record.offset + record.length])
	}

	private static func cmap(glyphs: [Int: Unicode.Scalar], mapping: [Int: Int]) -> [UInt8] {
		var scalarMap: [UInt32: Int] = [:]
		for (oldGlyph, scalar) in glyphs where oldGlyph != 0 {
			if let newGlyph = mapping[oldGlyph] { scalarMap[scalar.value] = newGlyph }
		}
		let entries = scalarMap.sorted { $0.key < $1.key }
		var groups: [(start: UInt32, end: UInt32, glyph: Int)] = []
		for (scalar, glyph) in entries {
			if let last = groups.last,
			   scalar == last.end + 1,
			   glyph == last.glyph + Int(scalar - last.start) {
				groups[groups.count - 1].end = scalar
			} else {
				groups.append((scalar, scalar, glyph))
			}
		}

		var subtable: [UInt8] = []
		appendUInt16(12, to: &subtable)
		appendUInt16(0, to: &subtable)
		appendUInt32(16 + groups.count * 12, to: &subtable)
		appendUInt32(0, to: &subtable) // language
		appendUInt32(groups.count, to: &subtable)
		for group in groups {
			appendUInt32(Int(group.start), to: &subtable)
			appendUInt32(Int(group.end), to: &subtable)
			appendUInt32(group.glyph, to: &subtable)
		}

		var result: [UInt8] = []
		appendUInt16(0, to: &result)
		appendUInt16(2, to: &result)
		appendUInt16(0, to: &result) // Unicode, full repertoire
		appendUInt16(4, to: &result)
		appendUInt32(20, to: &result)
		appendUInt16(3, to: &result) // Windows, UCS-4
		appendUInt16(10, to: &result)
		appendUInt32(20, to: &result)
		result += subtable
		return result
	}

	private static func sfnt(tables: [String: [UInt8]]) -> [UInt8] {
		let records = tables.sorted { $0.key < $1.key }
		let tableCount = records.count
		var power = 1
		var entrySelector = 0
		while power * 2 <= tableCount {
			power *= 2
			entrySelector += 1
		}

		var output: [UInt8] = []
		appendUInt32(0x0001_0000, to: &output)
		appendUInt16(tableCount, to: &output)
		appendUInt16(power * 16, to: &output)
		appendUInt16(entrySelector, to: &output)
		appendUInt16(tableCount * 16 - power * 16, to: &output)

		var body: [UInt8] = []
		var headOffset = 0
		let dataStart = 12 + tableCount * 16
		for (tag, bytes) in records {
			output += Array(tag.utf8)
			appendUInt32(Int(checksum(bytes)), to: &output)
			appendUInt32(dataStart + body.count, to: &output)
			appendUInt32(bytes.count, to: &output)
			if tag == "head" { headOffset = dataStart + body.count }
			body += bytes
			while body.count % 4 != 0 { body.append(0) }
		}
		output += body

		let adjustment = 0xB1B0_AFBA &- checksum(output)
		replaceUInt32(Int(adjustment), at: headOffset + 8, in: &output)
		return output
	}

	private static func checksum(_ bytes: [UInt8]) -> UInt32 {
		var result: UInt32 = 0
		var offset = 0
		while offset < bytes.count {
			var word: UInt32 = 0
			for index in 0 ..< 4 {
				word <<= 8
				if offset + index < bytes.count { word |= UInt32(bytes[offset + index]) }
			}
			result &+= word
			offset += 4
		}
		return result
	}

	private static func appendUInt16(_ value: Int, to bytes: inout [UInt8]) {
		bytes.append(UInt8((value >> 8) & 0xFF))
		bytes.append(UInt8(value & 0xFF))
	}

	private static func appendUInt32(_ value: Int, to bytes: inout [UInt8]) {
		bytes.append(UInt8((value >> 24) & 0xFF))
		bytes.append(UInt8((value >> 16) & 0xFF))
		bytes.append(UInt8((value >> 8) & 0xFF))
		bytes.append(UInt8(value & 0xFF))
	}

	private static func replaceUInt16(_ value: Int, at offset: Int, in bytes: inout [UInt8]) {
		guard offset >= 0, offset + 2 <= bytes.count else { return }
		bytes[offset] = UInt8((value >> 8) & 0xFF)
		bytes[offset + 1] = UInt8(value & 0xFF)
	}

	private static func replaceUInt32(_ value: Int, at offset: Int, in bytes: inout [UInt8]) {
		guard offset >= 0, offset + 4 <= bytes.count else { return }
		bytes[offset] = UInt8((value >> 24) & 0xFF)
		bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
		bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
		bytes[offset + 3] = UInt8(value & 0xFF)
	}
}
