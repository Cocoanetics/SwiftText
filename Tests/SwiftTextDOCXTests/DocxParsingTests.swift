import Foundation
import Testing

@testable import SwiftTextDOCX

@Suite("DOCX Parsing")
struct DocxParsingTests {
	@Test("Formats styles showcase with headings and lists")
	func parsesStylesDocument() throws {
		let url = try #require(
			Bundle.module.url(
				forResource: "Styles",
				withExtension: "docx"
			)
		)

		let docx = try DocxFile(url: url)
		let paragraphs = docx.markdownParagraphs().map(\.text)

		let expected = [
			"# Title",
			"## Subtitle",
			"# Heading",
			"## Heading 2",
			"### Subheading",
			"Normal body text",
			"A bullet list",
			"- One",
			"- Two",
			"- Three",
			"A numbered list",
			"1. One",
			"2. Two",
			"3. Three"
		]
		#expect(paragraphs == expected)
	}
}
