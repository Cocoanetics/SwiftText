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

	/// Viewers' own base-14 metrics disagree with the standard ones here and
	/// there; declared widths pin every advance to what layout measured.
	@Test("Base-14 fonts declare the widths layout measured with")
	func standardFontsDeclareWidths() async throws {
		let pdf = try await HTMLRenderer.renderPDF(html: "<p style=\"font-family: sans-serif\">±60.96</p>")
		let text = String(decoding: pdf, as: UTF8.self)
		let pattern = #"/BaseFont /Helvetica/[^>]*?/FirstChar 32/LastChar 255/Widths \[([0-9 ]+)\]"#
		let match = try #require(text.range(of: pattern, options: .regularExpression))
		let array = try #require(text[match].split(separator: "[").last?.dropLast())
		let widths = array.split(separator: " ").compactMap { Int($0) }
		#expect(widths.count == 224)
		#expect(widths[0xB1 - 32] == 584) // ±, 549 in macOS's Helvetica
		#expect(widths[0x80 - 32] == 556) // €
		#expect(widths[Int(Character("i").asciiValue!) - 32] == 222)
		#expect(widths[0x95 - 32] == 350) // •
	}

	/// Viewers draw the base-14 Euro at different widths — macOS's runs into
	/// the next digit — so it comes from a real face with the same metrics.
	@Test("The Euro sign is drawn from an installed metric-compatible face")
	func euroUsesMetricCompatibleFace() {
		#expect(!StandardFont.helvetica(bold: false, italic: false).covers("€"))
		#expect(!StandardFont.times(bold: true, italic: false).covers("€"))
		// Every viewer's Courier Euro is 600 units wide, like its other glyphs.
		#expect(StandardFont.courier(bold: false, italic: false).covers("€"))

		let candidates = [
			"/System/Library/Fonts/Supplemental/Arial.ttf",
			"/Library/Fonts/Arial.ttf",
			"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
			"/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
			"/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf"
		]
		var style = ComputedStyle.initial
		style.fontFamily = ["sans-serif"]
		let fonts = FontBook()
		let runs = fonts.resolveRuns("€60", style: style)
		guard candidates.contains(where: FileManager.default.fileExists(atPath:)) else {
			// Nothing to fall back to: the base-14 face draws it after all.
			#expect(runs.count == 1)
			return
		}
		#expect(runs.map(\.text) == ["€", "60"])
		guard case .embedded(let face) = runs.first?.font else {
			Issue.record("expected the Euro from an embedded face")
			return
		}
		#expect(abs(face.width(of: "€", size: 1000) - 556) < 1) // Helvetica's advance

		fonts.systemFallbackEnabled = false
		#expect(fonts.resolveRuns("€60", style: style).count == 1)
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
				"À": 722, "Ä": 722, "Ö": 722, "Ü": 722, "ß": 500, "Ç": 667, "æ": 667, "œ": 722,
				"‚": 333, "“": 444, "”": 444, "•": 350, "—": 1000, "…": 1000,
				"™": 980, "€": 500, "µ": 500, "¼": 750, "×": 564, "±": 564
			]),
			("Times-Italic", .times(bold: false, italic: true), [
				"A": 611, "À": 611, "Ä": 611, "Ö": 722, "Ü": 722, "ß": 500, "Ç": 667,
				"æ": 667, "œ": 667, "‚": 333, "“": 556, "”": 556, "•": 350,
				"—": 889, "…": 889, "™": 980, "€": 500, "µ": 500, "¼": 750,
				"×": 675, "±": 675
			]),
			("Times-Bold", .times(bold: true, italic: false), [
				"À": 722, "Ä": 722, "Ö": 778, "Ü": 722, "ß": 556, "Ç": 722, "æ": 722, "œ": 722,
				"‚": 333, "“": 500, "”": 500, "•": 350, "—": 1000, "…": 1000,
				"™": 1000, "€": 500, "µ": 556, "¼": 750, "×": 570, "±": 570
			]),
			("Times-BoldItalic", .times(bold: true, italic: true), [
				"A": 667, "À": 667, "Ä": 667, "Ö": 722, "Ü": 722, "ß": 500, "Ç": 667,
				"æ": 722, "œ": 722, "‚": 333, "“": 500, "”": 500, "•": 350,
				"—": 1000, "…": 1000, "™": 1000, "€": 500, "µ": 576, "¼": 750,
				"×": 570, "±": 570
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

@Suite("Standard faces are embedded")
struct EmbeddedStandardFaceTests {
	private func render(embedding: Bool) async throws -> String {
		let fonts = FontBook()
		fonts.embedsStandardFaces = embedding
		let pdf = try await HTMLRenderer.renderPDF(
			html: "<h1 style=\"font-family: sans-serif\">Titel</h1><p style=\"font-family: sans-serif\">Ein <b>fetter</b> Satz mit <i>Kursiv</i>.</p>",
			fonts: fonts)
		return String(decoding: pdf, as: UTF8.self)
	}

	@Test("font dictionaries are indirect objects, not inline in /Resources")
	func fontsAreIndirect() async throws {
		let text = try await render(embedding: false)
		#expect(text.contains("/BaseFont /Helvetica"))
		let font = try #require(text.range(of: "/Font <<"))
		let dictionary = text[font.upperBound...].prefix { $0 != ">" }
		#expect(!dictionary.contains("<<"))
		#expect(dictionary.contains(" 0 R"))
	}

	@Test("no base-14 font is left unembedded")
	func noUnembeddedBase14() async throws {
		let text = try await render(embedding: true)
		let installed = ["/System/Library/Fonts/Supplemental/Arial.ttf", "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
		                 "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"].contains { FileManager.default.fileExists(atPath: $0) }
		guard installed else { return }
		#expect(!text.contains("/BaseFont /Helvetica"))
		#expect(!text.contains("/Subtype /Type1"))
		#expect(text.contains("/FontFile2"))
		// Bold and regular at least; italic is its own face only where one is installed.
		#expect(text.components(separatedBy: "/FontFile2").count - 1 >= 2)
	}
}

@Suite("Installed named families")
struct InstalledNamedFamilyTests {
	private func render(_ fonts: FontBook) async throws -> String {
		let pdf = try await HTMLRenderer.renderPDF(
			html: "<p><a href=\"https://example.com/\" style=\"font-family: Menlo\">link 0O1l</a></p>", fonts: fonts)
		return String(decoding: pdf, as: UTF8.self)
	}

	@Test("an installed Menlo is used, not the monospace stand-in")
	func installedMenlo() async throws {
		guard FileManager.default.fileExists(atPath: "/System/Library/Fonts/Menlo.ttc") else { return }
		let fonts = FontBook()
		fonts.embedsStandardFaces = true
		let text = try await render(fonts)
		#expect(text.contains("Menlo"))
		#expect(!text.contains("CourierNew"))
	}

	@Test("a named family that is not available falls back to its generic class")
	func missingAliasFallsBackToMonospace() {
		let fonts = FontBook()
		fonts.systemFallbackEnabled = false // nothing installed is looked up
		var style = ComputedStyle.initial
		style.fontFamily = ["Menlo"]
		guard case .standard(let standard) = fonts.font(for: style) else { Issue.record("not a stand-in"); return }
		#expect(standard.baseFontName == "Courier")
	}
}

@Suite("Registered face selection")
struct RegisteredFaceSelectionTests {
	@Test("an italic request prefers an italic face over a same-weight upright one")
	func italicBeforeWeight() throws {
		let path = ["/System/Library/Fonts/Supplemental/Arial.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]
			.first { FileManager.default.fileExists(atPath: $0) }
		guard let path else { return }
		let data = try Data(contentsOf: URL(fileURLWithPath: path))
		let fonts = FontBook()
		try fonts.register(data: data, family: "Mine")
		let boldItalic = try fonts.register(data: data, family: "Mine", bold: true, italic: true)
		var style = ComputedStyle.initial
		style.fontFamily = ["Mine"]
		style.fontStyle = .italic
		guard case .embedded(let chosen) = fonts.font(for: style) else { Issue.record("not embedded"); return }
		#expect(chosen.postScriptName == boldItalic.postScriptName)
	}
}
