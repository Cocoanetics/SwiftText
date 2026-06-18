import Foundation
import Testing

@testable import SwiftTextPages

@Suite("PagesDocument rendering")
struct PagesDocumentTests {
	@Test("Promotes short, larger-font paragraphs to headings by ratio")
	func headingLevelsFromFontSize() {
		let document = PagesDocument(paragraphs: [
			.init(text: "Document Title", fontSize: 28, bold: true),
			.init(text: "A Section", fontSize: 17, bold: true),
			.init(text: "A Subsection", fontSize: 14, bold: false),
			.init(text: "Body text that establishes the dominant size.", fontSize: 11, bold: false),
			.init(text: "More body text at the same dominant size.", fontSize: 11, bold: false)
		])

		let markdown = document.markdown()
		#expect(markdown.contains("# Document Title"))
		#expect(markdown.contains("## A Section"))
		#expect(markdown.contains("### A Subsection"))
		#expect(markdown.contains("\nBody text that establishes the dominant size."))
		#expect(!markdown.contains("#### "))
	}

	@Test("Does not promote long paragraphs even when set larger")
	func longParagraphsStayBody() {
		let long = String(repeating: "word ", count: 60)
		let document = PagesDocument(paragraphs: [
			.init(text: long, fontSize: 20, bold: false),
			.init(text: "Body one.", fontSize: 11, bold: false),
			.init(text: "Body two.", fontSize: 11, bold: false)
		])
		#expect(!document.markdown().contains("#"))
	}

	@Test("Renders plain paragraphs when no font sizes are known")
	func noStyleInfoIsPlain() {
		let document = PagesDocument(paragraphs: [
			.init(text: "First paragraph."),
			.init(text: "Second paragraph.")
		])
		#expect(document.markdown() == "First paragraph.\n\nSecond paragraph.")
		#expect(document.plainText() == "First paragraph.\n\nSecond paragraph.")
	}

	@Test("Normalizes soft breaks and strips inline-object placeholders")
	func normalizesText() {
		let paragraph = PagesDocument.Paragraph(text: "Line one\u{2028}Line two\u{FFFC}")
		#expect(paragraph.normalizedText() == "Line one\nLine two")
	}

	@Test("Wraps emphasis spans in Markdown markers, leaving plain text unmarked")
	func inlineEmphasis() {
		// "B I X": "B" bold, "I" italic, "X" bold+italic (spans carry forward).
		let paragraph = PagesDocument.Paragraph(text: "B I X", emphasis: [
			.init(start: 0, bold: true, italic: false),
			.init(start: 2, bold: false, italic: true),
			.init(start: 4, bold: true, italic: true)
		])
		let document = PagesDocument(paragraphs: [paragraph])
		#expect(document.markdown() == "**B** *I* ***X***")
		#expect(document.plainText() == "B I X")
	}

	@Test("Renders strikethrough, wrapping any emphasis markers")
	func strikethrough() {
		let strikeOnly = PagesDocument.Paragraph(text: "xYz", emphasis: [
			.init(start: 0, bold: false, italic: false, strike: false),
			.init(start: 1, bold: false, italic: false, strike: true),
			.init(start: 2, bold: false, italic: false, strike: false)
		])
		let boldStrike = PagesDocument.Paragraph(text: "xYz", emphasis: [
			.init(start: 0, bold: false, italic: false, strike: false),
			.init(start: 1, bold: true, italic: false, strike: true),
			.init(start: 2, bold: false, italic: false, strike: false)
		])
		#expect(PagesDocument(paragraphs: [strikeOnly]).markdown() == "x~~Y~~z")
		#expect(PagesDocument(paragraphs: [boldStrike]).markdown() == "x~~**Y**~~z")
		#expect(PagesDocument(paragraphs: [strikeOnly]).plainText() == "xYz")
	}

	@Test("Renders bullet and numbered lists with nesting, counters, and tight spacing")
	func listRendering() {
		let document = PagesDocument(paragraphs: [
			.init(text: "First", listLevel: 0, listOrdered: true),
			.init(text: "Second", listLevel: 0, listOrdered: true),
			.init(text: "Nested", listLevel: 1, listOrdered: false),
			.init(text: "Third", listLevel: 0, listOrdered: true),
			.init(text: "Body paragraph."),
			.init(text: "A", listLevel: 0, listOrdered: false),
			.init(text: "B", listLevel: 0, listOrdered: false)
		])
		#expect(document.markdown() == """
		1. First
		2. Second
		  - Nested
		3. Third

		Body paragraph.

		- A
		- B
		""")
	}

	@Test("Drops empty paragraphs from output")
	func dropsEmptyParagraphs() {
		let document = PagesDocument(paragraphs: [
			.init(text: "Kept."),
			.init(text: "   "),
			.init(text: "\u{FFFC}"),
			.init(text: "Also kept.")
		])
		#expect(document.plainTextParagraphs() == ["Kept.", "Also kept."])
	}
}
