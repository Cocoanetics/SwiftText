//  Font.swift
//  SwiftTextRender
//
//  Font metrics and selection. Two kinds of font are supported behind one
//  `Font` value:
//   • base-14 (`StandardFont`): Helvetica/Courier with standard Adobe metrics,
//     reproduced by every viewer with no embedding.
//   • embedded (`EmbeddedFont`): any TrueType/OpenType font read by
//     SwiftTextOpenType, embedded into the PDF as a CIDFontType2 — this is what
//     makes the engine truly universal (arbitrary fonts and scripts).
//
//  With no fonts registered, FontBook returns base-14 faces (the default).

import Foundation
import SwiftTextCSS
import SwiftTextOpenType

/// A font selected for a run of text.
public enum Font {
	case standard(StandardFont)
	case embedded(EmbeddedFont)

	/// The advance width of `string` at `size`, in points/pixels.
	public func width(of string: String, size: Double) -> Double {
		switch self {
		case .standard(let font): return font.width(of: string, size: size)
		case .embedded(let font): return font.width(of: string, size: size)
		}
	}

	/// Ascent scaled to `size`.
	public func ascent(size: Double) -> Double {
		switch self {
		case .standard(let font): return font.ascent(size: size)
		case .embedded(let font): return font.ascent(size: size)
		}
	}

	/// Descent magnitude scaled to `size`.
	public func descent(size: Double) -> Double {
		switch self {
		case .standard(let font): return font.descent(size: size)
		case .embedded(let font): return font.descent(size: size)
		}
	}

	/// A stable identity used to deduplicate PDF font resources.
	var key: String {
		switch self {
		case .standard(let font): return "std:" + font.baseFontName
		case .embedded(let font): return "emb:" + font.postScriptName
		}
	}
}

/// A base-14 font (no embedding) with standard Adobe metrics in 1000-unit em.
public struct StandardFont: Equatable {
	public let baseFontName: String
	public let unitsPerEm: Double
	public let ascentUnits: Double
	public let descentUnits: Double

	private let widths: [Int: Double]
	private let defaultWidth: Double

	func advance(_ scalar: Unicode.Scalar) -> Double {
		widths[Int(scalar.value)] ?? defaultWidth
	}

	public func width(of string: String, size: Double) -> Double {
		var total = 0.0
		for scalar in string.unicodeScalars { total += advance(scalar) }
		return total * size / unitsPerEm
	}

	public func ascent(size: Double) -> Double { ascentUnits * size / unitsPerEm }
	public func descent(size: Double) -> Double { -descentUnits * size / unitsPerEm }
}

/// A TrueType/OpenType font embedded into the PDF.
public struct EmbeddedFont {
	let otf: OpenTypeFont
	/// The PDF BaseFont / PostScript name (no spaces).
	public let postScriptName: String

	public init(otf: OpenTypeFont, postScriptName: String) {
		self.otf = otf
		self.postScriptName = postScriptName
	}

	var unitsPerEm: Double { Double(otf.unitsPerEm) }
	var ascentUnits: Int { otf.ascent }
	var descentUnits: Int { otf.descent }
	var boundingBox: (xMin: Int, yMin: Int, xMax: Int, yMax: Int) { otf.boundingBox }
	var data: Data { otf.data }

	public func width(of string: String, size: Double) -> Double { otf.width(of: string, size: size) }
	public func ascent(size: Double) -> Double { Double(otf.ascent) * size / unitsPerEm }
	public func descent(size: Double) -> Double { -Double(otf.descent) * size / unitsPerEm }
	public func glyphID(for scalar: Unicode.Scalar) -> Int { otf.glyphID(for: scalar) ?? 0 }
	public func advanceWidth(glyph: Int) -> Int { otf.advanceWidth(glyph: glyph) }
}

/// Selects fonts for computed styles. Registered fonts (by family name) embed;
/// everything else falls back to base-14.
public final class FontBook {
	private var registered: [String: EmbeddedFont] = [:]

	public init() {}

	/// Register a TrueType/OpenType font to be used (and embedded) whenever a
	/// style's `font-family` names `family` (case-insensitive).
	@discardableResult
	public func register(data: Data, family: String, fontIndex: Int = 0) throws -> EmbeddedFont {
		let otf = try OpenTypeFont(data: data, fontIndex: fontIndex)
		let font = EmbeddedFont(otf: otf, postScriptName: Self.postScriptName(from: family))
		registered[family.lowercased()] = font
		return font
	}

	public func font(for style: ComputedStyle) -> Font {
		for family in style.fontFamily {
			if let embedded = registered[family.lowercased()] {
				return .embedded(embedded)
			}
		}
		let bold = style.fontWeight >= 600
		let italic = style.fontStyle != .normal
		switch Self.genericFamily(style.fontFamily) {
		case .monospace: return .standard(.courier(bold: bold, italic: italic))
		case .serif: return .standard(.times(bold: bold, italic: italic))
		case .sansSerif: return .standard(.helvetica(bold: bold, italic: italic))
		}
	}

	private enum GenericFamily { case serif, sansSerif, monospace }

	private static func genericFamily(_ families: [String]) -> GenericFamily {
		for family in families {
			switch family.lowercased() {
			case "monospace", "courier", "courier new", "menlo", "monaco", "consolas":
				return .monospace
			case "serif", "times", "times new roman", "georgia":
				return .serif
			case "sans-serif", "helvetica", "arial", "verdana", "system-ui":
				return .sansSerif
			default:
				continue
			}
		}
		return .sansSerif
	}

	private static func postScriptName(from family: String) -> String {
		let cleaned = family.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
		let name = String(String.UnicodeScalarView(cleaned))
		return name.isEmpty ? "EmbeddedFont" : name
	}
}

extension StandardFont {
	static func helvetica(bold: Bool, italic: Bool) -> StandardFont {
		let name: String
		switch (bold, italic) {
		case (true, true): name = "Helvetica-BoldOblique"
		case (true, false): name = "Helvetica-Bold"
		case (false, true): name = "Helvetica-Oblique"
		case (false, false): name = "Helvetica"
		}
		return StandardFont(baseFontName: name, unitsPerEm: 1000, ascentUnits: 718, descentUnits: -207,
		                    widths: bold ? helveticaBoldWidths : helveticaWidths, defaultWidth: bold ? 611 : 556)
	}

	static func times(bold: Bool, italic: Bool) -> StandardFont {
		let name: String
		switch (bold, italic) {
		case (true, true): name = "Times-BoldItalic"
		case (true, false): name = "Times-Bold"
		case (false, true): name = "Times-Italic"
		case (false, false): name = "Times-Roman"
		}
		return StandardFont(baseFontName: name, unitsPerEm: 1000, ascentUnits: 683, descentUnits: -217,
		                    widths: bold ? timesBoldWidths : timesWidths, defaultWidth: 500)
	}

	static func courier(bold: Bool, italic: Bool) -> StandardFont {
		let name: String
		switch (bold, italic) {
		case (true, true): name = "Courier-BoldOblique"
		case (true, false): name = "Courier-Bold"
		case (false, true): name = "Courier-Oblique"
		case (false, false): name = "Courier"
		}
		return StandardFont(baseFontName: name, unitsPerEm: 1000, ascentUnits: 629, descentUnits: -157,
		                    widths: [:], defaultWidth: 600)
	}
}

/// Adobe Helvetica advance widths for ASCII, in 1000-unit em space.
private let helveticaWidths: [Int: Double] = {
	let table: [Character: Double] = [
		" ": 278, "!": 278, "\"": 355, "#": 556, "$": 556, "%": 889, "&": 667, "'": 191,
		"(": 333, ")": 333, "*": 389, "+": 584, ",": 278, "-": 333, ".": 278, "/": 278,
		"0": 556, "1": 556, "2": 556, "3": 556, "4": 556, "5": 556, "6": 556, "7": 556,
		"8": 556, "9": 556, ":": 278, ";": 278, "<": 584, "=": 584, ">": 584, "?": 556,
		"@": 1015, "A": 667, "B": 667, "C": 722, "D": 722, "E": 667, "F": 611, "G": 778,
		"H": 722, "I": 278, "J": 500, "K": 667, "L": 556, "M": 833, "N": 722, "O": 778,
		"P": 667, "Q": 778, "R": 722, "S": 667, "T": 611, "U": 722, "V": 667, "W": 944,
		"X": 667, "Y": 667, "Z": 611, "[": 278, "\\": 278, "]": 278, "^": 469, "_": 556,
		"`": 333, "a": 556, "b": 556, "c": 500, "d": 556, "e": 556, "f": 278, "g": 556,
		"h": 556, "i": 222, "j": 222, "k": 500, "l": 222, "m": 833, "n": 556, "o": 556,
		"p": 556, "q": 556, "r": 333, "s": 500, "t": 278, "u": 556, "v": 500, "w": 722,
		"x": 500, "y": 500, "z": 500, "{": 334, "|": 260, "}": 334, "~": 584,
	]
	var widths: [Int: Double] = [:]
	for (character, width) in table {
		if let scalar = character.unicodeScalars.first {
			widths[Int(scalar.value)] = width
		}
	}
	return widths
}()

/// Build an ASCII width map from a character→width table.
private func asciiWidths(_ table: [Character: Double]) -> [Int: Double] {
	var widths: [Int: Double] = [:]
	for (character, width) in table {
		if let scalar = character.unicodeScalars.first {
			widths[Int(scalar.value)] = width
		}
	}
	return widths
}

/// Adobe Times-Roman advance widths for ASCII, in 1000-unit em space.
private let timesWidths = asciiWidths([
	" ": 250, "!": 333, "\"": 408, "#": 500, "$": 500, "%": 833, "&": 778, "'": 180,
	"(": 333, ")": 333, "*": 500, "+": 564, ",": 250, "-": 333, ".": 250, "/": 278,
	"0": 500, "1": 500, "2": 500, "3": 500, "4": 500, "5": 500, "6": 500, "7": 500,
	"8": 500, "9": 500, ":": 278, ";": 278, "<": 564, "=": 564, ">": 564, "?": 444,
	"@": 921, "A": 722, "B": 667, "C": 667, "D": 722, "E": 611, "F": 556, "G": 722,
	"H": 722, "I": 333, "J": 389, "K": 722, "L": 611, "M": 889, "N": 722, "O": 722,
	"P": 556, "Q": 722, "R": 667, "S": 556, "T": 611, "U": 722, "V": 722, "W": 944,
	"X": 722, "Y": 722, "Z": 611, "[": 333, "\\": 278, "]": 333, "^": 469, "_": 500,
	"`": 333, "a": 444, "b": 500, "c": 444, "d": 500, "e": 444, "f": 333, "g": 500,
	"h": 500, "i": 278, "j": 278, "k": 500, "l": 278, "m": 778, "n": 500, "o": 500,
	"p": 500, "q": 500, "r": 333, "s": 389, "t": 278, "u": 500, "v": 500, "w": 722,
	"x": 500, "y": 500, "z": 444, "{": 480, "|": 200, "}": 480, "~": 541,
])

/// Adobe Times-Bold advance widths for ASCII, in 1000-unit em space.
private let timesBoldWidths = asciiWidths([
	" ": 250, "!": 333, "\"": 555, "#": 500, "$": 500, "%": 1000, "&": 833, "'": 278,
	"(": 333, ")": 333, "*": 500, "+": 570, ",": 250, "-": 333, ".": 250, "/": 278,
	"0": 500, "1": 500, "2": 500, "3": 500, "4": 500, "5": 500, "6": 500, "7": 500,
	"8": 500, "9": 500, ":": 333, ";": 333, "<": 570, "=": 570, ">": 570, "?": 500,
	"@": 930, "A": 722, "B": 667, "C": 722, "D": 722, "E": 667, "F": 611, "G": 778,
	"H": 778, "I": 389, "J": 500, "K": 778, "L": 667, "M": 944, "N": 722, "O": 778,
	"P": 611, "Q": 778, "R": 722, "S": 556, "T": 667, "U": 722, "V": 722, "W": 1000,
	"X": 722, "Y": 722, "Z": 667, "[": 333, "\\": 278, "]": 333, "^": 581, "_": 500,
	"`": 333, "a": 500, "b": 556, "c": 444, "d": 556, "e": 444, "f": 333, "g": 500,
	"h": 556, "i": 278, "j": 333, "k": 556, "l": 278, "m": 833, "n": 556, "o": 500,
	"p": 556, "q": 556, "r": 444, "s": 389, "t": 333, "u": 556, "v": 500, "w": 722,
	"x": 500, "y": 500, "z": 444, "{": 394, "|": 220, "}": 394, "~": 520,
])

/// Adobe Helvetica-Bold advance widths for ASCII, in 1000-unit em space.
private let helveticaBoldWidths: [Int: Double] = {
	let table: [Character: Double] = [
		" ": 278, "!": 333, "\"": 474, "#": 556, "$": 556, "%": 889, "&": 722, "'": 238,
		"(": 333, ")": 333, "*": 389, "+": 584, ",": 278, "-": 333, ".": 278, "/": 278,
		"0": 556, "1": 556, "2": 556, "3": 556, "4": 556, "5": 556, "6": 556, "7": 556,
		"8": 556, "9": 556, ":": 333, ";": 333, "<": 584, "=": 584, ">": 584, "?": 611,
		"@": 975, "A": 722, "B": 722, "C": 722, "D": 722, "E": 667, "F": 611, "G": 778,
		"H": 722, "I": 278, "J": 556, "K": 722, "L": 611, "M": 833, "N": 722, "O": 778,
		"P": 667, "Q": 778, "R": 722, "S": 667, "T": 611, "U": 722, "V": 667, "W": 944,
		"X": 667, "Y": 667, "Z": 611, "[": 333, "\\": 278, "]": 333, "^": 584, "_": 556,
		"`": 333, "a": 556, "b": 611, "c": 556, "d": 611, "e": 556, "f": 333, "g": 611,
		"h": 611, "i": 278, "j": 278, "k": 556, "l": 278, "m": 889, "n": 611, "o": 611,
		"p": 611, "q": 611, "r": 389, "s": 556, "t": 333, "u": 611, "v": 556, "w": 778,
		"x": 556, "y": 556, "z": 500, "{": 389, "|": 280, "}": 389, "~": 584,
	]
	var widths: [Int: Double] = [:]
	for (character, width) in table {
		if let scalar = character.unicodeScalars.first {
			widths[Int(scalar.value)] = width
		}
	}
	return widths
}()
