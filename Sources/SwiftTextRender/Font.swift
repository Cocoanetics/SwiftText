//  Font.swift
//  SwiftTextRender
//
//  Font metrics and selection for the renderer. This first stage uses the PDF
//  base-14 fonts (Helvetica, Courier) — no font files, no embedding — with
//  their standard Adobe metrics, which every PDF viewer reproduces exactly.
//  Embedding arbitrary OpenType fonts (via SwiftTextOpenType) is layered on
//  later; the same `Font`/`FontBook` interface will carry it.

import Foundation
import SwiftTextCSS

/// A resolved font: a base-14 face with metrics in 1000-unit em space.
public struct Font: Equatable {
	/// The PDF BaseFont name, e.g. `Helvetica-Bold`.
	public let baseFontName: String
	public let unitsPerEm: Double
	/// Ascent in font units (positive).
	public let ascent: Double
	/// Descent in font units (negative).
	public let descent: Double

	private let widths: [Int: Double]
	private let defaultWidth: Double

	func advance(_ scalar: Unicode.Scalar) -> Double {
		widths[Int(scalar.value)] ?? defaultWidth
	}

	/// The advance width of a string at `size`, in points/pixels.
	public func width(of string: String, size: Double) -> Double {
		var total = 0.0
		for scalar in string.unicodeScalars { total += advance(scalar) }
		return total * size / unitsPerEm
	}

	/// Ascent scaled to `size`.
	public func ascent(size: Double) -> Double { ascent * size / unitsPerEm }
	/// Descent magnitude scaled to `size`.
	public func descent(size: Double) -> Double { -descent * size / unitsPerEm }
}

/// Selects fonts for computed styles, mapping CSS families to base-14 faces.
public final class FontBook {
	public init() {}

	public func font(for style: ComputedStyle) -> Font {
		let bold = style.fontWeight >= 600
		let italic = style.fontStyle != .normal
		switch resolvedFamily(style.fontFamily) {
		case .monospace:
			return Font.courier(bold: bold, italic: italic)
		case .sansSerif, .serif:
			// Times metrics are added later; serif currently maps to Helvetica.
			return Font.helvetica(bold: bold, italic: italic)
		}
	}

	private enum GenericFamily { case serif, sansSerif, monospace }

	private func resolvedFamily(_ families: [String]) -> GenericFamily {
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
}

extension Font {
	static func helvetica(bold: Bool, italic: Bool) -> Font {
		let name: String
		switch (bold, italic) {
		case (true, true): name = "Helvetica-BoldOblique"
		case (true, false): name = "Helvetica-Bold"
		case (false, true): name = "Helvetica-Oblique"
		case (false, false): name = "Helvetica"
		}
		return Font(baseFontName: name, unitsPerEm: 1000, ascent: 718, descent: -207,
		            widths: helveticaWidths, defaultWidth: 556)
	}

	static func courier(bold: Bool, italic: Bool) -> Font {
		let name: String
		switch (bold, italic) {
		case (true, true): name = "Courier-BoldOblique"
		case (true, false): name = "Courier-Bold"
		case (false, true): name = "Courier-Oblique"
		case (false, false): name = "Courier"
		}
		// Courier is monospaced: every glyph advances 600 units.
		return Font(baseFontName: name, unitsPerEm: 1000, ascent: 629, descent: -157,
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
