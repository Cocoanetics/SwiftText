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

	@Test("Word's own Quote and Intense Quote styles read as quotes")
	func wordQuoteStyles() {
		#expect(DocxStyleID.isBlockQuote(styleId: "Quote", name: "Quote"))
		#expect(DocxStyleID.isBlockQuote(styleId: "IntenseQuote", name: "Intense Quote"))
		#expect(!DocxStyleID.isBlockQuote(styleId: "Normal", name: "Normal"))
	}
}
