import Foundation
import Testing

@testable import SwiftTextDOCX

/// Block quotes and code blocks survive Markdown → DOCX → Markdown (#113): quotes by
/// their "Block Quote" style (nesting by indent), code blocks by "Code Block".
@Suite("DOCX block quotes and code blocks round-trip")
struct DocxQuoteCodeTests {
	private func url() -> URL {
		FileManager.default.temporaryDirectory.appendingPathComponent("swifttext-quote-\(UUID().uuidString).docx")
	}

	private func roundTrip(_ markdown: String) throws -> String {
		let url = url()
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToDocx.convert(markdown, to: url)
		return try DocxFile(url: url).markdown()
	}

	@Test("Block quotes read back as quotes, nested levels included")
	func quotesRoundTrip() throws {
		let markdown = """
		Before.

		> A quoted paragraph.
		>
		> A second one, with **bold**.

		> Outer
		>
		> > Inner quote

		After.
		"""
		#expect(try roundTrip(markdown) == markdown)
	}

	@Test("Code blocks read back fenced, keeping indentation, blank lines and backticks")
	func codeBlocksRoundTrip() throws {
		let markdown = """
		```
		let x = 1

		  indented()
		```

		````
		```
		inner fence
		```
		````
		"""
		#expect(try roundTrip(markdown) == markdown)
	}

	@Test("Quoted paragraphs use the Block Quote style; deeper levels indent further")
	func quoteStyle() throws {
		let url = url()
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToDocx.convert("> One\n>\n> > Two\n", to: url)
		let archive = try DocxArchive(contentsOf: url)
		let document = try archive.text("word/document.xml")
		let styles = try archive.text("word/styles.xml")
		#expect(document.contains("<w:pStyle w:val=\"SwiftTextBlockQuote\"/></w:pPr><w:r><w:t xml:space=\"preserve\">One"))
		#expect(document.contains("<w:pStyle w:val=\"SwiftTextBlockQuote\"/><w:ind w:left=\"\(2 * DocxWriter.quoteIndent)\"/>"))
		#expect(styles.contains("<w:name w:val=\"Block Quote\"/>"))
	}

	@Test("A quote and a second paragraph inside a list item are kept, indented under the item (#261)")
	func listItemContent() throws {
		let url = url()
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToDocx.convert("- Punkt\n    > Zitat im Punkt\n\n- Taufe 1814\n\n    Eintrag: x\n", to: url)
		let document = try DocxArchive(contentsOf: url).text("word/document.xml")
		let textIndent = 720
		#expect(document.contains(
			"<w:pStyle w:val=\"SwiftTextBlockQuote\"/><w:ind w:left=\"\(textIndent + DocxWriter.quoteIndent)\"/></w:pPr>"
				+ "<w:r><w:t xml:space=\"preserve\">Zitat im Punkt"
		))
		#expect(document.contains("<w:p><w:pPr><w:ind w:left=\"\(textIndent)\"/></w:pPr><w:r><w:t xml:space=\"preserve\">Eintrag: x"))
		#expect(!document.contains("Taufe 1814Eintrag"))
	}

	@Test("Content nested in list items reads back indented under its item, numbering running on")
	func listItemContentRoundTrip() throws {
		let markdown = """
		- Punkt

		  > Zitat im Punkt

		- Taufe 1814

		  Eintrag: x

		  - Nested

		    More

		1. One

		   > Quoted

		2. Two
		"""
		#expect(try roundTrip(markdown) == markdown)
	}

	@Test("Code blocks and tables in a list item stay under it; a following top-level quote stays separate")
	func listItemCodeTableAndQuoteRoundTrip() throws {
		let markdown = """
		- Item

		  ```
		  code
		  ```

		  | A | B |
		  | --- | --- |
		  | 1 | 2 |

		  > Inner

		> Outer
		"""
		#expect(try roundTrip(markdown) == markdown)
	}

	@Test("Rules and alert boxes in a list item stay under it; an alert after a list stays at top level")
	func listItemRuleAndAlertRoundTrip() throws {
		let rule = """
		1. a

		   ---

		2. b
		"""
		#expect(try roundTrip(rule) == rule)
		let alerts = """
		- c

		  > [!NOTE]
		  > n

		- d

		> [!WARNING]
		> - w
		"""
		#expect(try roundTrip(alerts) == alerts)
	}

	@Test("A deeply nested quote after a list stays at top level, though indented like the item's text")
	func nestedQuoteAfterListRoundTrip() throws {
		let markdown = """
		- a

		> > > deep
		"""
		#expect(try roundTrip(markdown) == markdown)
		// A code block or table inside a quote after a list isn't adopted by the item.
		for nested in ["> >     code", "> > | A |\n> > | --- |\n> > | 1 |"] {
			let readBack = try roundTrip("- a\n\n" + nested)
			#expect(!readBack.contains("\n  "), "\(readBack)")
		}
	}

	@Test("Word's own Quote and Intense Quote styles read as quotes")
	func wordQuoteStyles() {
		#expect(DocxStyleID.isBlockQuote(styleId: "Quote", name: "Quote"))
		#expect(DocxStyleID.isBlockQuote(styleId: "IntenseQuote", name: "Intense Quote"))
		#expect(!DocxStyleID.isBlockQuote(styleId: "Normal", name: "Normal"))
	}
}
