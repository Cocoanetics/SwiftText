//  OpenTypeTests.swift
//  SwiftTextOpenTypeTests

import Testing
import Foundation
@testable import SwiftTextOpenType

@Suite("OpenType")
struct OpenTypeTests {

	// MARK: - Minimal hand-built font

	/// Build a tiny but valid sfnt font in memory so the parser can be tested
	/// deterministically with no external fixtures.
	///
	/// It has four glyphs — `.notdef`, `A`, `B`, space — with known advances and
	/// a format-4 cmap mapping `A`→1, `B`→2, space→3.
	private func makeMinimalFont() -> Data {
		func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
		func u32(_ v: Int) -> [UInt8] {
			[UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
		}
		func i16(_ v: Int) -> [UInt8] { u16(v & 0xFFFF) }

		var head: [UInt8] = []
		head += u16(1) + u16(0)            // version 1.0
		head += u32(0)                      // fontRevision
		head += u32(0)                      // checksumAdjustment
		head += u32(0x5F0F3CF5)             // magicNumber
		head += u16(0)                      // flags
		head += u16(1000)                   // unitsPerEm
		head += u32(0) + u32(0)             // created
		head += u32(0) + u32(0)             // modified
		head += i16(0) + i16(-200) + i16(1000) + i16(800) // bbox
		head += u16(0)                      // macStyle
		head += u16(0)                      // lowestRecPPEM
		head += i16(0)                      // fontDirectionHint
		head += i16(0)                      // indexToLocFormat
		head += i16(0)                      // glyphDataFormat

		var hhea: [UInt8] = []
		hhea += u16(1) + u16(0)             // version 1.0
		hhea += i16(800) + i16(-200) + i16(0) // ascender, descender, lineGap
		hhea += u16(0)                      // advanceWidthMax
		hhea += i16(0) + i16(0) + i16(0)    // min LSB, min RSB, xMaxExtent
		hhea += i16(0) + i16(0) + i16(0)    // caret slope rise/run, caret offset
		hhea += i16(0) + i16(0) + i16(0) + i16(0) // reserved
		hhea += i16(0)                      // metricDataFormat
		hhea += u16(4)                      // numberOfHMetrics

		var maxp: [UInt8] = []
		maxp += u32(0x00010000)             // version 1.0
		maxp += u16(4)                      // numGlyphs

		var hmtx: [UInt8] = []
		hmtx += u16(500) + i16(0)           // .notdef
		hmtx += u16(600) + i16(0)           // A
		hmtx += u16(700) + i16(0)           // B
		hmtx += u16(250) + i16(0)           // space

		var sub: [UInt8] = []
		sub += u16(4) + u16(40) + u16(0)    // format, length, language
		sub += u16(6) + u16(4) + u16(1) + u16(2) // segCountX2, searchRange, entrySelector, rangeShift
		sub += u16(0x20) + u16(0x42) + u16(0xFFFF) // endCode
		sub += u16(0)                       // reservedPad
		sub += u16(0x20) + u16(0x41) + u16(0xFFFF) // startCode
		sub += i16(-29) + i16(-64) + i16(1) // idDelta
		sub += u16(0) + u16(0) + u16(0)     // idRangeOffset

		var cmap: [UInt8] = []
		cmap += u16(0) + u16(1)             // version, numTables
		cmap += u16(3) + u16(1) + u32(12)   // (3,1) record at offset 12
		cmap += sub

		let tables: [(String, [UInt8])] = [
			("cmap", cmap), ("head", head), ("hhea", hhea), ("hmtx", hmtx), ("maxp", maxp),
		]

		var sfnt: [UInt8] = []
		sfnt += u32(0x00010000) + u16(tables.count)
		let entrySelector = Int(floor(log2(Double(tables.count))))
		let searchRange = 16 * Int(pow(2, Double(entrySelector)))
		sfnt += u16(searchRange) + u16(entrySelector) + u16(tables.count * 16 - searchRange)

		var records: [UInt8] = []
		var body: [UInt8] = []
		let dataStart = 12 + 16 * tables.count
		for (tag, bytes) in tables {
			records += Array(tag.utf8) + u32(0) + u32(dataStart + body.count) + u32(bytes.count)
			body += bytes
			while body.count % 4 != 0 { body.append(0) }
		}
		return Data(sfnt + records + body)
	}

	@Test("Parses head/hhea/maxp metrics")
	func metrics() throws {
		let font = try OpenTypeFont(data: makeMinimalFont())
		#expect(font.unitsPerEm == 1000)
		#expect(font.ascent == 800)
		#expect(font.descent == -200)
		#expect(font.lineGap == 0)
		#expect(font.numGlyphs == 4)
		#expect(font.boundingBox.xMin == 0)
		#expect(font.boundingBox.yMin == -200)
		#expect(font.boundingBox.xMax == 1000)
		#expect(font.boundingBox.yMax == 800)
	}

	@Test("Maps characters to glyphs via the format-4 cmap")
	func cmapLookup() throws {
		let font = try OpenTypeFont(data: makeMinimalFont())
		#expect(font.glyphID(for: "A") == 1)
		#expect(font.glyphID(for: "B") == 2)
		#expect(font.glyphID(for: " ") == 3)
		#expect(font.glyphID(for: "Z") == nil) // unmapped
	}

	@Test("Reads advance widths from hmtx")
	func advances() throws {
		let font = try OpenTypeFont(data: makeMinimalFont())
		#expect(font.advanceWidth(glyph: 0) == 500)
		#expect(font.advanceWidth(glyph: 1) == 600)
		#expect(font.advanceWidth(for: "A") == 600)
		#expect(font.advanceWidth(for: "B") == 700)
		#expect(font.advanceWidth(for: " ") == 250)
	}

	@Test("Measures strings in font units and points")
	func measurement() throws {
		let font = try OpenTypeFont(data: makeMinimalFont())
		#expect(font.advanceWidth(of: "AB") == 1300)
		#expect(font.width(of: "AB", size: 1000) == 1300)
		#expect(abs(font.width(of: "AB", size: 12) - 15.6) < 1e-9)
	}

	@Test("Rejects non-sfnt data")
	func rejectsGarbage() {
		#expect(throws: OpenTypeError.self) {
			_ = try OpenTypeFont(data: Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B]))
		}
	}

	// MARK: - Real-font integration (best effort, macOS)

	#if os(macOS)
	@Test("Parses a real system font when one is available")
	func realFont() throws {
		let candidates = [
			"/System/Library/Fonts/SFNS.ttf",
			"/System/Library/Fonts/Helvetica.ttc",
			"/System/Library/Fonts/Geneva.ttf",
			"/System/Library/Fonts/Monaco.ttf",
			"/System/Library/Fonts/Supplemental/Arial.ttf",
			"/System/Library/Fonts/Supplemental/Times New Roman.ttf",
		]
		guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
			return // No known font present; nothing to assert.
		}
		let data = try Data(contentsOf: URL(fileURLWithPath: path))
		let font = try OpenTypeFont(data: data)
		#expect(font.unitsPerEm > 0)
		#expect(font.numGlyphs > 0)
		#expect(font.glyphID(for: "A") != nil)
		#expect(font.width(of: "Hello", size: 12) > 0)
	}
	#endif
}
