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
		#expect(!helvetica.covers("\u{0628}"))  // Arabic beh
		#expect(!helvetica.covers("\u{4E00}"))  // CJK
	}

	#if os(macOS)
	@Test("Digits missing from an Arabic font fall back to base-14")
	func arabicDigitsFallBack() throws {
		let candidates = [
			"/System/Library/Fonts/Supplemental/Damascus.ttc",
			"/System/Library/Fonts/Supplemental/AlBayan.ttc",
			"/System/Library/Fonts/Supplemental/Baghdad.ttc",
			"/System/Library/Fonts/Supplemental/Nadeem.ttc",
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
