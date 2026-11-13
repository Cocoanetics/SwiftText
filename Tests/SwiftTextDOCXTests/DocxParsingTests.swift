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

	/// Native Word tables must round-trip to a GFM pipe table via `docx -m`, not
	/// flatten into bold header paragraphs (#258).
	@Test("Markdown table round-trips through DOCX as a GFM pipe table")
	func markdownTableRoundTrips() throws {
		let markdown = """
		# Report

		| A | B |
		| --- | --- |
		| 1 | 2 |
		"""
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("docx-table-roundtrip-\(UUID().uuidString).docx")
		defer { try? FileManager.default.removeItem(at: url) }

		try MarkdownToDocx.convert(markdown, to: url)
		let output = try DocxFile(url: url).markdown()
		let paragraphs = try DocxFile(url: url).markdownParagraphs().map(\.text)

		#expect(output.hasPrefix("# Report"))
		// A real pipe table (MarkupFormatter's compact GFM), not flattened bold headers.
		#expect(!paragraphs.contains("**A**"))
		#expect(!paragraphs.contains("**B**"))
		#expect(paragraphs.contains(where: { $0.contains("|") && $0.contains("A") && $0.contains("B") }))
		#expect(paragraphs.contains(where: { $0.contains("|") && $0.contains("1") && $0.contains("2") }))
		#expect(output.contains("|A|B|") || output.contains("| A | B |"))
		#expect(output.contains("|1|2|") || output.contains("| 1 | 2 |"))
	}
}
