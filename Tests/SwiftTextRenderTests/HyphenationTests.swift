//  HyphenationTests.swift
//  SwiftTextRenderTests

import Foundation
import Testing
@testable import SwiftTextRender
import SwiftTextCSS
import SwiftTextHTML

@Suite("Hyphenation")
struct HyphenationTests {
	private static let german = "Die Medikamentensicherheit, Bewegungseinschränkungen und Blutdruckmessungen sind "
		+ "Voraussetzungen für Krankenhausaufenthalte, Impfempfehlungen und Gleichgewichtstraining "
		+ "bei Parkinson-Erkrankungen in Österreich."

	// MARK: - Liang patterns

	@Test("German patterns split compounds at syllable and compound boundaries")
	func germanBreakPoints() throws {
		let hyphenator = try #require(Hyphenator.forLanguage("de-AT"))
		#expect(pieces("Medikamentensicherheit", hyphenator) == "Me-di-ka-men-ten-si-cher-heit")
		#expect(pieces("Bewegungseinschränkungen", hyphenator) == "Be-we-gungs-ein-schrän-kun-gen")
	}

	@Test("English patterns and exceptions apply")
	func englishBreakPoints() throws {
		let hyphenator = try #require(Hyphenator.forLanguage("en-GB"))
		#expect(pieces("hyphenation", hyphenator) == "hy-phen-ation")
		#expect(pieces("associate", hyphenator) == "as-so-ciate")
	}

	@Test("Every shipped language has patterns; unknown ones have none", arguments: ["de", "en", "fr", "es", "it", "nl", "de_CH"])
	func shippedLanguages(_ language: String) {
		#expect(Hyphenator.forLanguage(language) != nil)
	}

	@Test("Unknown or missing languages are not hyphenated")
	func unknownLanguage() {
		#expect(Hyphenator.forLanguage("ja") == nil)
		#expect(Hyphenator.forLanguage(nil) == nil)
	}

	@Test("Short words and punctuation are left alone")
	func minimumLength() throws {
		let hyphenator = try #require(Hyphenator.forLanguage("de"))
		#expect(hyphenator.breakOffsets(in: "Haus").isEmpty)
		let withComma = hyphenator.breakOffsets(in: "Medikamentensicherheit,")
		#expect(withComma == hyphenator.breakOffsets(in: "Medikamentensicherheit"))
	}

	// MARK: - Layout

	@Test("hyphens: auto splits long German compounds in a narrow justified column")
	func autoHyphenation() async throws {
		let lines = try await layout(hyphens: "auto", lang: "de-AT")
		#expect(lines.contains { $0.hasSuffix("-") })
		#expect(lines.contains { $0.hasSuffix("Medikamenten-") || $0.hasSuffix("Medikamentensicher-") || $0.hasSuffix("Medika-") })
		// Dehyphenated, the text is intact.
		let joined = lines.reduce("") { $0.hasSuffix("-") ? String($0.dropLast()) + $1 : $0 + " " + $1 }
		#expect(joined.trimmingCharacters(in: .whitespaces) == Self.german)
	}

	@Test("hyphens: manual and none never split the same words")
	func noAutomaticHyphenation() async throws {
		for mode in ["manual", "none"] {
			let lines = try await layout(hyphens: mode, lang: "de-AT")
			#expect(!lines.contains { $0.hasSuffix("sicher-") || $0.hasSuffix("Medikamenten-") })
			#expect(lines.contains { $0 == "Medikamentensicherheit," })
		}
	}

	@Test("An empty lang clears the inherited language")
	func emptyLanguageOverride() async throws {
		let html = "<html lang=\"de\"><body><p lang=\"\" style=\"hyphens: auto\">Medikamentensicherheit</p></body></html>"
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		let styled = StyledElement.build(domElement: try #require(builder.root), resolver: StyleResolver())
		let rootBox = try #require(BoxTreeBuilder.build(from: styled) as? BlockBox)
		let paragraph = try #require(firstParagraph(in: rootBox))
		#expect(paragraph.style.language == "")
	}

	@Test("-webkit-hyphens shares the hyphens cascade slot")
	func prefixedHyphens() async throws {
		let lines = try await layout(hyphens: "none; -webkit-hyphens: auto; hyphens: none", lang: "de")
		#expect(lines.contains { $0 == "Medikamentensicherheit," })
	}

	@Test("auto without a known language does nothing")
	func noLanguage() async throws {
		let lines = try await layout(hyphens: "auto", lang: nil)
		#expect(lines.contains { $0 == "Medikamentensicherheit," })
	}

	@Test("A soft hyphen is invisible until a line breaks there")
	func softHyphen() async throws {
		let text = "Donau\u{00AD}dampf\u{00AD}schiff\u{00AD}fahrt"
		let wide = try await layout(hyphens: "manual", lang: nil, text: text, width: 600)
		#expect(wide == ["Donaudampfschifffahrt"])
		let narrow = try await layout(hyphens: "manual", lang: nil, text: text, width: 100)
		#expect(narrow.count > 1)
		#expect(narrow.dropLast().allSatisfy { $0.hasSuffix("-") })
		let none = try await layout(hyphens: "none", lang: nil, text: text, width: 100)
		#expect(none == ["Donaudampfschifffahrt"])
	}

	// MARK: - Helpers

	private func pieces(_ word: String, _ hyphenator: Hyphenator) -> String {
		let offsets = hyphenator.breakOffsets(in: word)
		var result = ""
		for (index, character) in word.enumerated() {
			if offsets.contains(index) { result += "-" }
			result.append(character)
		}
		return result
	}

	/// Lines of a 5 cm (189 px) justified paragraph.
	private func layout(hyphens: String, lang: String?, text: String = HyphenationTests.german,
	                    width: Double = 189) async throws -> [String] {
		let langAttribute = lang.map { " lang=\"\($0)\"" } ?? ""
		let html = "<html\(langAttribute)><body><p style=\"text-align: justify; hyphens: \(hyphens)\">\(text)</p></body></html>"
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		let root = try #require(builder.root)
		let styled = StyledElement.build(domElement: root, resolver: StyleResolver())
		let rootBox = try #require(BoxTreeBuilder.build(from: styled) as? BlockBox)
		LayoutEngine(fonts: FontBook()).layout(root: rootBox, contentWidth: width, originX: 0, originY: 0)
		let paragraph = try #require(firstParagraph(in: rootBox))
		return paragraph.lines.map { line in
			var text = ""
			var previousEnd: Double?
			for fragment in line.fragments {
				if let previousEnd, fragment.x - previousEnd > 0.5 { text += " " }
				text += fragment.text
				previousEnd = fragment.x + fragment.width
			}
			return text
		}
	}

	private func firstParagraph(in box: BlockBox) -> BlockBox? {
		if box.element?.localName == "p" { return box }
		for case let child as BlockBox in box.children {
			if let found = firstParagraph(in: child) { return found }
		}
		return nil
	}
}
