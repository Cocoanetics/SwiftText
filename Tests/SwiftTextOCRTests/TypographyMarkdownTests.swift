//
//  TypographyMarkdownTests.swift
//  SwiftTextOCRTests
//

import Foundation
import Testing

@testable import SwiftTextOCR

/// A page says "this is 22pt bold", never "this is a heading". These cover the
/// step from the one to the other, and the emphasis recovered along the way.
struct TypographyMarkdownTests {

	// MARK: - Headings from size

	@Test("Sizes above body become heading levels, deepest size first")
	func sizesAboveBodyBecomeLevels() {
		let markdown = render([
			heading("Erste", size: 22),
			heading("Zweite", size: 16.5),
			heading("Dritte", size: 13.75),
			body("Ein Absatz mit genug Text, damit elf Punkt die Grundschrift ist.")
		])
		#expect(markdown.contains("# Erste"))
		#expect(markdown.contains("## Zweite"))
		#expect(markdown.contains("### Dritte"))
	}

	/// The levels come from the document's own scale, not from a table of point
	/// sizes: the same structure set in a different scale reads the same.
	@Test("Heading levels follow the document's own scale", arguments: [
		(CGFloat(22), CGFloat(16.5), CGFloat(11)),
		(CGFloat(40), CGFloat(30), CGFloat(20)),
		(CGFloat(13), CGFloat(12), CGFloat(10))
	])
	func levelsFollowTheDocumentsScale(_ sizes: (first: CGFloat, second: CGFloat, body: CGFloat)) {
		let markdown = render([
			heading("Erste", size: sizes.first),
			heading("Zweite", size: sizes.second),
			body("Ein Absatz mit genug Text, damit die Grundschrift eindeutig ist.", size: sizes.body)
		])
		#expect(markdown.contains("# Erste"))
		#expect(markdown.contains("## Zweite"))
	}

	@Test("Body text is whichever size sets the most characters")
	func bodyIsTheMostCommonSize() {
		// The 22pt heading comes first and is bold; only character count keeps it
		// from being taken for the body.
		let typography = DocumentTypography(blocks: [
			heading("Titel", size: 22),
			body("Ein Absatz mit deutlich mehr Text als die Überschrift darüber.")
		])
		#expect(typography.bodySize == 11)
		#expect(typography.headingLevel(forSize: 22) == 1)
		#expect(typography.headingLevel(forSize: 11) == nil)
	}

	@Test("One large word in a sentence is emphasis, not a heading")
	func oneLargeWordIsNotAHeading() {
		let markdown = render([
			DocumentBlock(bounds: rect(0), kind: .paragraph(.init(
				text: "", lines: [line([
					run("Ein Satz mit einem ", size: 11),
					run("großen", size: 22),
					run(" Wort darin.", size: 11)
				])]))),
			body("Noch ein Absatz, damit elf Punkt klar die Grundschrift ist.")
		])
		#expect(!markdown.contains("#"))
	}

	// MARK: - Headings at body size

	/// A stylesheet often stops scaling at `h4`, leaving it bold body text —
	/// indistinguishable from a bold sentence except by shape.
	@Test("A bold body-size line without sentence punctuation is a heading")
	func boldLineWithoutPunctuationIsAHeading() {
		let markdown = render([
			heading("Groß", size: 22),
			body("Ein Absatz mit genug Text, damit elf Punkt die Grundschrift ist."),
			DocumentBlock(bounds: rect(2), kind: .paragraph(.init(
				text: "", lines: [line([run("Vierte Ebene", size: 11, bold: true)])])))
		])
		#expect(markdown.contains("## Vierte Ebene"))
	}

	@Test("A bold body-size line that ends a sentence stays a paragraph", arguments: [
		"Ein komplett fetter Absatz.",
		"Ist das eine Überschrift?",
		"Das ist wichtig!",
		"Hinweis:"
	])
	func boldSentenceStaysAParagraph(_ text: String) {
		let markdown = render([
			body("Ein Absatz mit genug Text, damit elf Punkt die Grundschrift ist."),
			DocumentBlock(bounds: rect(2), kind: .paragraph(.init(
				text: "", lines: [line([run(text, size: 11, bold: true)])])))
		])
		#expect(markdown.contains("**\(text)**"))
		#expect(!markdown.contains("#"))
	}

	@Test("A long bold passage is a paragraph even without punctuation")
	func longBoldPassageStaysAParagraph() {
		let text = "Ein sehr langer fett gesetzter Absatz der eindeutig keine Überschrift "
			+ "ist weil er viel zu viele Wörter enthält um als Titel zu gelten"
		let markdown = render([
			body("Ein Absatz mit genug Text, damit elf Punkt die Grundschrift ist."),
			DocumentBlock(bounds: rect(2), kind: .paragraph(.init(
				text: "", lines: [line([run(text, size: 11, bold: true)])])))
		])
		#expect(!markdown.contains("#"))
	}

	// MARK: - Inline emphasis

	@Test("Bold, italic and monospaced runs become emphasis")
	func runsBecomeEmphasis() {
		let markdown = render([
			DocumentBlock(bounds: rect(0), kind: .paragraph(.init(
				text: "", lines: [line([
					run("Dies ist ", size: 11),
					run("fett", size: 11, bold: true),
					run(" und ", size: 11),
					run("kursiv", size: 11, italic: true),
					run(" und ", size: 11),
					run("code", size: 11, monospaced: true),
					run(".", size: 11)
				])])))
		])
		#expect(markdown.contains("Dies ist **fett** und *kursiv* und `code`."))
	}

	@Test("Bold italic nests both emphases")
	func boldItalicNests() {
		let markdown = render([
			DocumentBlock(bounds: rect(0), kind: .paragraph(.init(
				text: "", lines: [line([
					run("Ein ", size: 11),
					run("starkes", size: 11, bold: true, italic: true),
					run(" Wort.", size: 11)
				])])))
		])
		#expect(markdown.contains("***starkes***") || markdown.contains("**_starkes_**"))
	}

	/// A page hands over `"fett "`, space included. Markdown closes emphasis on
	/// a non-space character, so `**fett **` would not be emphasis at all.
	@Test("Whitespace inside a run moves outside the emphasis")
	func whitespaceMovesOutsideEmphasis() {
		let markdown = render([
			DocumentBlock(bounds: rect(0), kind: .paragraph(.init(
				text: "", lines: [line([
					run("Hier steht ", size: 11),
					run("wichtig ", size: 11, bold: true),
					run("mitten im Satz.", size: 11)
				])])))
		])
		#expect(markdown.contains("**wichtig** mitten"))
		#expect(!markdown.contains("**wichtig **"))
	}

	@Test("A heading's own weight is not written as emphasis too")
	func headingWeightIsNotEmphasis() {
		let markdown = render([
			heading("Hauptüberschrift", size: 22),
			body("Ein Absatz mit genug Text, damit elf Punkt die Grundschrift ist.")
		])
		#expect(markdown.contains("# Hauptüberschrift"))
		#expect(!markdown.contains("**Hauptüberschrift**"))
	}

	@Test("Emphasis survives inside a list item")
	func emphasisInsideAListItem() {
		let item = DocumentBlock.List.Item(
			text: "", markerString: "",
			bounds: rect(0),
			lines: [line([run("Punkt eins mit ", size: 11), run("fett", size: 11, bold: true)])])
		let markdown = render([
			DocumentBlock(bounds: rect(0), kind: .list(.init(marker: .bullet, items: [item])))
		])
		#expect(markdown.contains("- Punkt eins mit **fett**"))
	}

	// MARK: - No style available

	/// OCR reports characters and geometry but no font, so a page read that way
	/// must come out exactly as it did before any of this existed.
	@Test("Text without style stays plain")
	func textWithoutStyleStaysPlain() {
		let markdown = render([
			DocumentBlock(bounds: rect(0), kind: .paragraph(.init(
				text: "Ein Absatz ganz ohne Stilinformation.",
				lines: [DocumentBlock.TextLine(text: "Ein Absatz ganz ohne Stilinformation.", bounds: rect(0))])))
		])
		#expect(markdown.trimmingCharacters(in: .whitespacesAndNewlines)
			== "Ein Absatz ganz ohne Stilinformation.")
	}

	@Test("A paragraph styled on only some lines stays plain")
	func partiallyStyledParagraphStaysPlain() {
		let markdown = render([
			DocumentBlock(bounds: rect(0), kind: .paragraph(.init(
				text: "",
				lines: [
					line([run("Erste Zeile ", size: 11), run("fett", size: 11, bold: true)]),
					DocumentBlock.TextLine(text: "zweite Zeile ohne Stil.", bounds: rect(1))
				])))
		])
		#expect(!markdown.contains("**"))
	}

	// MARK: - Helpers

	private func render(_ blocks: [DocumentBlock]) -> String {
		DocumentBlockMarkdownRenderer.markdown(from: blocks)
	}

	private func rect(_ index: Int) -> CGRect {
		CGRect(x: 0, y: CGFloat(index) * 40, width: 400, height: 20)
	}

	private func run(
		_ text: String, size: CGFloat,
		bold: Bool = false, italic: Bool = false, monospaced: Bool = false
	) -> StyleRun {
		StyleRun(text: text, style: TextStyle(
			fontSize: size, isBold: bold, isItalic: italic, isMonospaced: monospaced))
	}

	private func line(_ runs: [StyleRun], at index: Int = 0) -> DocumentBlock.TextLine {
		DocumentBlock.TextLine(runs: runs, bounds: rect(index))
	}

	private func heading(_ text: String, size: CGFloat) -> DocumentBlock {
		DocumentBlock(bounds: rect(0), kind: .paragraph(.init(
			text: "", lines: [line([run(text, size: size, bold: true)])])))
	}

	private func body(_ text: String, size: CGFloat = 11) -> DocumentBlock {
		DocumentBlock(bounds: rect(1), kind: .paragraph(.init(
			text: "", lines: [line([run(text, size: size)], at: 1)])))
	}
}
