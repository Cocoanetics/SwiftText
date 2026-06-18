//  Cmap.swift
//  SwiftTextOpenType
//
//  Character-to-glyph mapping. Supports the common Unicode subtable formats
//  0 (byte), 4 (segmented BMP), 6 (trimmed) and 12 (segmented full). Format 4
//  and 12 cover the overwhelming majority of real fonts.

import Foundation

/// A parsed `cmap` subtable that maps Unicode scalars to glyph indices.
struct CmapSubtable {
	private enum Storage {
		case format0(glyphIDs: [Int])
		case format4(end: [Int], start: [Int], delta: [Int], rangeOffset: [Int], rangeOffsetBase: Int, fonts: FontBytes)
		case format6(firstCode: Int, glyphIDs: [Int])
		case format12(groups: [(start: UInt32, end: UInt32, startGlyph: UInt32)])
	}

	private let storage: Storage

	/// Parse the subtable that begins at `offset`.
	init?(fonts: FontBytes, offset: Int) {
		guard let format = try? fonts.u16(offset) else { return nil }
		do {
			switch format {
			case 0:
				var glyphIDs = [Int](repeating: 0, count: 256)
				for code in 0 ..< 256 {
					glyphIDs[code] = try fonts.u8(offset + 6 + code)
				}
				storage = .format0(glyphIDs: glyphIDs)
			case 4:
				let segCount = try fonts.u16(offset + 6) / 2
				var cursor = offset + 14
				let end = try (0 ..< segCount).map { try fonts.u16(cursor + $0 * 2) }
				cursor += segCount * 2 + 2 // skip reservedPad
				let start = try (0 ..< segCount).map { try fonts.u16(cursor + $0 * 2) }
				cursor += segCount * 2
				let delta = try (0 ..< segCount).map { try fonts.i16(cursor + $0 * 2) }
				cursor += segCount * 2
				let rangeOffsetBase = cursor
				let rangeOffset = try (0 ..< segCount).map { try fonts.u16(cursor + $0 * 2) }
				storage = .format4(end: end, start: start, delta: delta, rangeOffset: rangeOffset, rangeOffsetBase: rangeOffsetBase, fonts: fonts)
			case 6:
				let firstCode = try fonts.u16(offset + 6)
				let entryCount = try fonts.u16(offset + 8)
				let glyphIDs = try (0 ..< entryCount).map { try fonts.u16(offset + 10 + $0 * 2) }
				storage = .format6(firstCode: firstCode, glyphIDs: glyphIDs)
			case 12:
				let groupCount = try fonts.u32(offset + 12)
				var groups: [(start: UInt32, end: UInt32, startGlyph: UInt32)] = []
				groups.reserveCapacity(groupCount)
				for index in 0 ..< groupCount {
					let base = offset + 16 + index * 12
					let startChar = try fonts.u32(base)
					let endChar = try fonts.u32(base + 4)
					let startGlyph = try fonts.u32(base + 8)
					groups.append((UInt32(startChar), UInt32(endChar), UInt32(startGlyph)))
				}
				storage = .format12(groups: groups)
			default:
				return nil
			}
		} catch {
			return nil
		}
	}

	/// The glyph index for `scalar`, or `nil` if it maps to `.notdef`/unmapped.
	func glyphID(for scalar: Unicode.Scalar) -> Int? {
		let code = scalar.value
		let glyph: Int
		switch storage {
		case .format0(let glyphIDs):
			guard code < 256 else { return nil }
			glyph = glyphIDs[Int(code)]
		case .format4(let end, let start, let delta, let rangeOffset, let rangeOffsetBase, let fonts):
			guard code <= 0xFFFF else { return nil }
			let value = Int(code)
			// Segments are sorted ascending by end code.
			var segment = 0
			while segment < end.count && end[segment] < value {
				segment += 1
			}
			guard segment < end.count, start[segment] <= value else { return nil }
			if rangeOffset[segment] == 0 {
				glyph = (value + delta[segment]) & 0xFFFF
			} else {
				let glyphOffset = rangeOffsetBase + segment * 2 + rangeOffset[segment] + (value - start[segment]) * 2
				guard let raw = try? fonts.u16(glyphOffset), raw != 0 else { return nil }
				glyph = (raw + delta[segment]) & 0xFFFF
			}
		case .format6(let firstCode, let glyphIDs):
			let value = Int(code)
			guard value >= firstCode, value - firstCode < glyphIDs.count else { return nil }
			glyph = glyphIDs[value - firstCode]
		case .format12(let groups):
			var result: Int?
			for group in groups where code >= group.start && code <= group.end {
				result = Int(group.startGlyph + (code - group.start))
				break
			}
			guard let mapped = result else { return nil }
			glyph = mapped
		}
		return glyph == 0 ? nil : glyph
	}
}

extension CmapSubtable {
	/// Parse a `cmap` table and return its best Unicode subtable.
	///
	/// Preference order favours full-repertoire Unicode subtables, then BMP
	/// Unicode, then symbol tables.
	static func best(fonts: FontBytes, cmapOffset: Int) -> CmapSubtable? {
		guard let count = try? fonts.u16(cmapOffset + 2) else { return nil }
		var bestScore = Int.min
		var bestOffset: Int?
		for index in 0 ..< count {
			let record = cmapOffset + 4 + index * 8
			guard let platform = try? fonts.u16(record),
			      let encoding = try? fonts.u16(record + 2),
			      let subOffset = try? fonts.u32(record + 4) else { continue }
			let score: Int
			switch (platform, encoding) {
			case (3, 10): score = 5        // Windows, UCS-4
			case (0, 4), (0, 6): score = 4 // Unicode, full repertoire
			case (3, 1): score = 3         // Windows, BMP
			case (0, _): score = 3         // Unicode platform
			case (3, 0): score = 1         // Windows, Symbol
			default: score = 0
			}
			if score > bestScore {
				bestScore = score
				bestOffset = cmapOffset + subOffset
			}
		}
		guard let offset = bestOffset else { return nil }
		return CmapSubtable(fonts: fonts, offset: offset)
	}
}
