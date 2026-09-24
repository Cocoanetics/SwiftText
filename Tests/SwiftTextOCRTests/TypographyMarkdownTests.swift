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

	@Test("A large inline word does not consume a heading level")
	func inlineSizeDoesNotPolluteHeadingLevels() {
		let markdown = render([
			DocumentBlock(bounds: rect(0), kind: .paragraph(.init(
				text: "", lines: [line([
					run("Ein Satz mit ", size: 11),
					run("Dekoration", size: 24, bold: true),
					run(" im Fließtext.", size: 11)
				])]))),
			heading("Echte Überschrift", size: 18),
			body("Noch ein längerer Absatz bestimmt eindeutig die Grundschrift.")
		])
		#expect(markdown.contains("# Echte Überschrift"))
		#expect(!markdown.contains("## Echte Überschrift"))
	}

	@Test("A nearby large title is not merged into body text")
	func nearbyTitleStaysSeparate() {
		let titleBounds = CGRect(x: 0, y: 0, width: 400, height: 20)
		let bodyBounds = CGRect(x: 0, y: 23, width: 400, height: 20)
		let markdown = render([
			DocumentBlock(bounds: titleBounds, kind: .paragraph(.init(
				text: "", lines: [.init(runs: [run("Titel", size: 22, bold: true)], bounds: titleBounds)]))),
			DocumentBlock(bounds: bodyBounds, kind: .paragraph(.init(
				text: "", lines: [.init(runs: [run(
					"Ein deutlich längerer Absatz bestimmt die Grundschrift.", size: 11)], bounds: bodyBounds)])))
		])
		#expect(markdown.contains("# Titel\n\nEin deutlich längerer Absatz"))
	}

	@Test("An explicit heading level survives continuation reconstruction")
	func explicitHeadingLevelSurvives() {
		let headingBounds = CGRect(x: 0, y: 0, width: 400, height: 20)
		let bodyBounds = CGRect(x: 0, y: 23, width: 400, height: 20)
		let headingLine = DocumentBlock.TextLine(text: "Explizite Ebene", bounds: headingBounds)
		let bodyLine = DocumentBlock.TextLine(text: "Body text.", bounds: bodyBounds)
		let markdown = render([
			DocumentBlock(bounds: headingBounds, kind: .paragraph(.init(
				text: headingLine.text, lines: [headingLine], headingLevel: 3))),
			DocumentBlock(bounds: bodyBounds, kind: .paragraph(.init(
				text: bodyLine.text, lines: [bodyLine])))
		])
		#expect(markdown.contains("### Explizite Ebene\n\nBody text."))
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

	@Test("A smaller bold caption is not a body-size heading")
	func smallerBoldCaptionStaysAParagraph() {
		let markdown = render([
			body("Ein Absatz mit genug Text, damit elf Punkt die Grundschrift ist."),
			DocumentBlock(bounds: rect(3), kind: .paragraph(.init(
				text: "", lines: [line([run("Figure 1", size: 9, bold: true)], at: 3)])))
		])
		#expect(markdown.contains("**Figure 1**"))
		#expect(!markdown.contains("# Figure 1"))
	}

	@Test("A two-line bold body paragraph is not a heading")
	func multilineBoldBodyStaysAParagraph() {
		let markdown = render([
			body("Ein Absatz mit genug Text, damit elf Punkt die Grundschrift ist."),
			DocumentBlock(bounds: rect(3), kind: .paragraph(.init(
				text: "",
				lines: [
					line([run("Important information", size: 11, bold: true)], at: 3),
					line([run("please read carefully", size: 11, bold: true)], at: 4)
				])))
		])
		#expect(markdown.contains("**Important information please read carefully**"))
		#expect(!markdown.contains("# Important information"))
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

	@Test("Larger inline styles survive when their paragraph is not a heading")
	func largerInlineStylesSurvive() {
		let markdown = render([
			DocumentBlock(bounds: rect(0), kind: .paragraph(.init(
				text: "", lines: [line([
					run("Mit ", size: 11),
					run("groß", size: 16, bold: true),
					run(", ", size: 11),
					run("schräg", size: 16, italic: true),
					run(" und ", size: 11),
					run("Code", size: 16, monospaced: true),
					run(" im Satz.", size: 11)
				])]))),
			body("Noch ein längerer Absatz bestimmt eindeutig die Grundschrift.")
		])
		#expect(markdown.contains("Mit **groß**, *schräg* und `Code` im Satz."))
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

	@Test("Distinct inline styles survive inside an inferred heading")
	func inlineStylesSurviveInsideInferredHeading() {
		let markdown = render([
			DocumentBlock(bounds: rect(0), kind: .paragraph(.init(
				text: "", lines: [line([
					run("Titel mit ", size: 22, bold: true),
					run("Betonung", size: 22, bold: true, italic: true),
					run(" und ", size: 22, bold: true),
					run("Code", size: 22, bold: true, monospaced: true)
				])]))),
			body("Ein Absatz mit genug Text, damit elf Punkt die Grundschrift ist.")
		])
		#expect(markdown.contains("# Titel mit *Betonung* und `Code`"))
		#expect(!markdown.contains("**Titel mit"))
	}

	@Test("Distinct inline emphasis survives inside an explicit heading")
	func inlineEmphasisSurvivesInsideExplicitHeading() {
		let headingLine = line([
			run("Explizit mit ", size: 11),
			run("Betonung", size: 11, italic: true)
		])
		let markdown = render([
			DocumentBlock(bounds: rect(0), kind: .paragraph(.init(
				text: "", lines: [headingLine], headingLevel: 3))),
			body("Ein Absatz mit genug Text, damit elf Punkt die Grundschrift ist.")
		])
		#expect(markdown.contains("### Explizit mit *Betonung*"))
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
