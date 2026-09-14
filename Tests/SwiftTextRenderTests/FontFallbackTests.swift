//  FontFallbackTests.swift
//  SwiftTextRenderTests

import Testing
import Foundation
@testable import SwiftTextRender
import SwiftTextCSS

@Suite("Font fallback")
struct FontFallbackTests {

	@Test("Single-font text stays one run")
	func singleRun() {
		let fonts = FontBook()
		let runs = fonts.resolveRuns("Hello, world!", style: .initial)
		#expect(runs.count == 1)
		#expect(runs[0].text == "Hello, world!")
	}

	@Test("Base-14 fonts cover CP1252 but not Arabic")
	func base14Coverage() {
		let helvetica = StandardFont.helvetica(bold: false, italic: false)
		#expect(helvetica.covers("2"))
		#expect(helvetica.covers("\u{2014}"))   // em dash (CP1252)
		#expect(!helvetica.covers("\u{007F}"))  // non-printing CP1252 control
		#expect(!helvetica.covers("\u{0628}"))  // Arabic beh
		#expect(!helvetica.covers("\u{4E00}"))  // CJK
	}

	@Test("Base-14 fonts use Adobe WinAnsi advances")
	func base14WinAnsiAdvances() {
		let cases: [(String, StandardFont, [Character: Double])] = [
			("Helvetica", .helvetica(bold: false, italic: false), [
				"Ä": 667, "Ö": 778, "Ü": 722, "ß": 611, "Ç": 722, "æ": 889, "œ": 944,
				"‚": 222, "“": 333, "”": 333, "•": 350, "—": 1000, "…": 1000,
				"™": 1000, "€": 556, "µ": 556, "¼": 834, "×": 584, "±": 584
			]),
			("Helvetica-Bold", .helvetica(bold: true, italic: false), [
				"Ä": 722, "Ö": 778, "Ü": 722, "ß": 611, "Ç": 722, "æ": 889, "œ": 944,
				"‚": 278, "“": 500, "”": 500, "•": 350, "—": 1000, "…": 1000,
				"™": 1000, "€": 556, "µ": 611, "¼": 834, "×": 584, "±": 584
			]),
			("Times-Roman", .times(bold: false, italic: false), [
				"Ä": 722, "Ö": 722, "Ü": 722, "ß": 500, "Ç": 667, "æ": 667, "œ": 722,
				"‚": 333, "“": 444, "”": 444, "•": 350, "—": 1000, "…": 1000,
				"™": 980, "€": 500, "µ": 500, "¼": 750, "×": 564, "±": 564
			]),
			("Times-Bold", .times(bold: true, italic: false), [
				"Ä": 722, "Ö": 778, "Ü": 722, "ß": 556, "Ç": 722, "æ": 722, "œ": 722,
				"‚": 333, "“": 500, "”": 500, "•": 350, "—": 1000, "…": 1000,
				"™": 1000, "€": 500, "µ": 556, "¼": 750, "×": 570, "±": 570
			])
		]

		for (name, font, expected) in cases {
			for (character, width) in expected {
				let scalar = character.unicodeScalars.first!
				#expect(font.advance(scalar) == width, "\(name): \(character)")
			}
		}
	}

	#if os(macOS)
	@Test("Digits missing from an Arabic font fall back to base-14")
	func arabicDigitsFallBack() throws {
		let candidates = [
			"/System/Library/Fonts/Supplemental/Damascus.ttc",
			"/System/Library/Fonts/Supplemental/AlBayan.ttc",
			"/System/Library/Fonts/Supplemental/Baghdad.ttc",
			"/System/Library/Fonts/Supplemental/Nadeem.ttc"
		]
		guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
			return
		}
		let data = try Data(contentsOf: URL(fileURLWithPath: path))
		let fonts = FontBook()
		let arabic = try fonts.register(data: data, family: "Arabic")
		// This test needs a font with Arabic letters but no ASCII digit '2'.
		guard arabic.hasGlyph(for: "\u{0628}"), !arabic.hasGlyph(for: "2") else { return }

		var style = ComputedStyle.initial
		style.fontFamily = ["Arabic"]
		// beh | 2 | beh → three runs; the digit splits out to a base-14 face.
		let runs = fonts.resolveRuns("\u{0628}2\u{0628}", style: style)
		#expect(runs.count == 3)
		#expect(runs[0].font.key == Font.embedded(arabic).key)
		#expect(runs[2].font.key == Font.embedded(arabic).key)
		if case .standard(let standard) = runs[1].font {
			#expect(standard.covers("2"))
		} else {
			Issue.record("digit run did not fall back to a base-14 font: \(runs[1].font.key)")
		}
	}
	#endif
}
