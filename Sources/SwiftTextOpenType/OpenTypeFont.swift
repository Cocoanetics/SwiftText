//  OpenTypeFont.swift
//  SwiftTextOpenType
//
//  Parses an sfnt font's metric tables and exposes the data the layout engine
//  needs: units per em, ascent/descent, glyph advances, character-to-glyph
//  mapping, and the raw bytes for PDF embedding.

import Foundation

/// A parsed TrueType/OpenType font.
///
/// This reader covers horizontal metrics and Unicode character mapping — enough
/// to measure and lay out Latin (and other simple-script) text and to embed the
/// font in a PDF. It does not perform complex shaping (ligatures, contextual
/// substitution, bidi); that is layered on later.
public struct OpenTypeFont {
	/// The raw font bytes, suitable for embedding (`FontFile2` / `FontFile3`).
	public let data: Data

	/// Font design units per em (the coordinate space of all metrics below).
	public let unitsPerEm: Int
	/// Typographic ascent in font units (positive, from `hhea`).
	public let ascent: Int
	/// Typographic descent in font units (negative, from `hhea`).
	public let descent: Int
	/// Recommended extra line spacing in font units (from `hhea`).
	public let lineGap: Int
	/// Number of glyphs in the font.
	public let numGlyphs: Int
	/// The font bounding box in font units.
	public let boundingBox: (xMin: Int, yMin: Int, xMax: Int, yMax: Int)

	/// Weight class, 1–1000 (from `OS/2`, default 400 / regular).
	public let weightClass: Int
	/// Whether the font is styled bold.
	public let isBold: Bool
	/// Whether the font is styled italic/oblique.
	public let isItalic: Bool
	/// Italic angle in degrees, counter-clockwise from vertical (from `post`).
	public let italicAngle: Double
	/// Whether the font is monospaced (from `post`).
	public let isFixedPitch: Bool

	private let fonts: FontBytes
	private let hmtxOffset: Int
	private let numberOfHMetrics: Int
	private let cmap: CmapSubtable?

	/// Parse a font from raw bytes.
	///
	/// - Parameters:
	///   - data: The font file bytes (`.ttf`, `.otf`, or a `.ttc` collection).
	///   - fontIndex: Which font to read from a collection (ignored otherwise).
	public init(data: Data, fontIndex: Int = 0) throws {
		self.data = data
		let fonts = FontBytes(data)
		self.fonts = fonts

		// Resolve the offset table, following a collection header if present.
		let firstTag = try fonts.tag(0)
		let tableDirectory: Int
		if firstTag == "ttcf" {
			let numFonts = try fonts.u32(8)
			guard fontIndex >= 0, fontIndex < numFonts else {
				throw OpenTypeError.fontIndexOutOfRange(fontIndex)
			}
			tableDirectory = try fonts.u32(12 + fontIndex * 4)
		} else {
			let version = try fonts.u32(0)
			// 0x00010000 = TrueType, 'OTTO' = CFF, 'true'/'typ1' = legacy Apple.
			let accepted = [0x0001_0000, 0x4F54_544F, 0x7472_7565, 0x7479_7031]
			guard accepted.contains(version) else {
				throw OpenTypeError.notSFNT(tag: firstTag)
			}
			tableDirectory = 0
		}

		// Read the table directory into a tag → (offset, length) map.
		let numTables = try fonts.u16(tableDirectory + 4)
		var tables: [String: (offset: Int, length: Int)] = [:]
		for index in 0 ..< numTables {
			let record = tableDirectory + 12 + index * 16
			let tag = try fonts.tag(record)
			let offset = try fonts.u32(record + 8)
			let length = try fonts.u32(record + 12)
			tables[tag] = (offset, length)
		}

		func require(_ tag: String) throws -> Int {
			guard let table = tables[tag] else { throw OpenTypeError.missingTable(tag) }
			return table.offset
		}

		// head: units per em, bounding box, mac style.
		let head = try require("head")
		unitsPerEm = try fonts.u16(head + 18)
		boundingBox = (
			try fonts.i16(head + 36),
			try fonts.i16(head + 38),
			try fonts.i16(head + 40),
			try fonts.i16(head + 42)
		)
		let macStyle = try fonts.u16(head + 44)

		// hhea: vertical metrics and the count of horizontal metrics.
		let hhea = try require("hhea")
		ascent = try fonts.i16(hhea + 4)
		descent = try fonts.i16(hhea + 6)
		lineGap = try fonts.i16(hhea + 8)
		numberOfHMetrics = try fonts.u16(hhea + 34)

		// maxp: glyph count.
		let maxp = try require("maxp")
		numGlyphs = try fonts.u16(maxp + 4)

		// hmtx: advance widths.
		hmtxOffset = try require("hmtx")

		// OS/2 (optional): weight and style refinements.
		if let os2 = tables["OS/2"]?.offset {
			weightClass = (try? fonts.u16(os2 + 4)) ?? 400
			let fsSelection = (try? fonts.u16(os2 + 62)) ?? 0
			isItalic = (macStyle & 0x0001) != 0 || (fsSelection & 0x0001) != 0
			isBold = (macStyle & 0x0002) != 0 || (fsSelection & 0x0020) != 0
		} else {
			weightClass = 400
			isItalic = (macStyle & 0x0001) != 0
			isBold = (macStyle & 0x0002) != 0
		}

		// post (optional): italic angle and fixed pitch.
		if let post = tables["post"]?.offset {
			let mantissa = (try? fonts.i16(post + 4)) ?? 0
			let fraction = (try? fonts.u16(post + 6)) ?? 0
			italicAngle = Double(mantissa) + Double(fraction) / 65536.0
			isFixedPitch = ((try? fonts.u32(post + 12)) ?? 0) != 0
		} else {
			italicAngle = 0
			isFixedPitch = false
		}

		// cmap (optional): character mapping.
		if let cmapOffset = tables["cmap"]?.offset {
			cmap = CmapSubtable.best(fonts: fonts, cmapOffset: cmapOffset)
		} else {
			cmap = nil
		}
	}

	// MARK: - Glyphs and advances

	/// The glyph index for a Unicode scalar, or `nil` if unmapped.
	public func glyphID(for scalar: Unicode.Scalar) -> Int? {
		cmap?.glyphID(for: scalar)
	}

	/// The advance width of a glyph in font units.
	///
	/// Glyphs at or beyond `numberOfHMetrics` share the last entry's advance,
	/// per the `hmtx` format (monospaced trailing runs).
	public func advanceWidth(glyph: Int) -> Int {
		guard glyph >= 0, numberOfHMetrics > 0 else { return 0 }
		let index = min(glyph, numberOfHMetrics - 1)
		return (try? fonts.u16(hmtxOffset + index * 4)) ?? 0
	}

	/// The advance width of a scalar in font units (`.notdef` if unmapped).
	public func advanceWidth(for scalar: Unicode.Scalar) -> Int {
		advanceWidth(glyph: glyphID(for: scalar) ?? 0)
	}

	/// The glyph indices for each scalar of `string` (`.notdef` where unmapped).
	public func glyphIDs(for string: String) -> [Int] {
		string.unicodeScalars.map { glyphID(for: $0) ?? 0 }
	}

	// MARK: - Measurement

	/// Convert a value in font units to points at the given font size.
	public func scale(_ fontUnits: Int, size: Double) -> Double {
		guard unitsPerEm > 0 else { return 0 }
		return Double(fontUnits) * size / Double(unitsPerEm)
	}

	/// The total advance of `string` in font units, summing per-scalar advances.
	///
	/// This is a metrics-only measurement: no kerning, ligatures or shaping.
	public func advanceWidth(of string: String) -> Int {
		var total = 0
		for scalar in string.unicodeScalars {
			total += advanceWidth(for: scalar)
		}
		return total
	}

	/// The width of `string` in points at the given font size.
	public func width(of string: String, size: Double) -> Double {
		scale(advanceWidth(of: string), size: size)
	}
}
