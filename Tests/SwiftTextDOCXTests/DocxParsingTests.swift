import Foundation
import SwiftTextZip
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

	/// Partial bold in a header cell must survive; only uniform (force-bold) headers
	/// drop bold markers (#259 review).
	@Test("Table headers keep intentional partial bold")
	func tableHeaderKeepsPartialBold() throws {
		let documentXML = """
		<?xml version="1.0" encoding="UTF-8"?>
		<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\
		<w:tbl>\
		<w:tr>\
		<w:tc><w:p>\
		<w:r><w:t xml:space="preserve">Revenue </w:t></w:r>\
		<w:r><w:rPr><w:b/></w:rPr><w:t>2026</w:t></w:r>\
		</w:p></w:tc>\
		<w:tc><w:p><w:r><w:t>Notes</w:t></w:r></w:p></w:tc>\
		</w:tr>\
		<w:tr>\
		<w:tc><w:p><w:r><w:t>1</w:t></w:r></w:p></w:tc>\
		<w:tc><w:p><w:r><w:t>ok</w:t></w:r></w:p></w:tc>\
		</w:tr>\
		</w:tbl>\
		</w:body></w:document>
		"""
		let url = try makeDocx(documentXML: documentXML)
		defer { try? FileManager.default.removeItem(at: url) }
		let output = try DocxFile(url: url).markdown()
		#expect(output.contains("Revenue") && output.contains("**2026**"))
		#expect(output.contains("Notes"))
		#expect(output.contains("|"))
	}

	/// `w:gridSpan` cells expand to placeholder columns so later unmerged rows keep
	/// their positions (#259 review).
	@Test("Horizontally merged header cells expand to the grid width")
	func tableGridSpanExpandsColumns() throws {
		let documentXML = """
		<?xml version="1.0" encoding="UTF-8"?>
		<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\
		<w:tbl>\
		<w:tr>\
		<w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr>\
		<w:p><w:r><w:t>Merged</w:t></w:r></w:p></w:tc>\
		<w:tc><w:p><w:r><w:t>Right</w:t></w:r></w:p></w:tc>\
		</w:tr>\
		<w:tr>\
		<w:tc><w:p><w:r><w:t>a</w:t></w:r></w:p></w:tc>\
		<w:tc><w:p><w:r><w:t>b</w:t></w:r></w:p></w:tc>\
		<w:tc><w:p><w:r><w:t>c</w:t></w:r></w:p></w:tc>\
		</w:tr>\
		</w:tbl>\
		</w:body></w:document>
		"""
		let url = try makeDocx(documentXML: documentXML)
		defer { try? FileManager.default.removeItem(at: url) }
		let table = try #require(DocxFile(url: url).document.paragraphs.first?.tables.first)
		#expect(table.cells.count == 2)
		#expect(table.cells[0].count == 3)
		#expect(table.cells[0][0] == "Merged")
		#expect(table.cells[0][1] == "")
		#expect(table.cells[0][2] == "Right")
		#expect(table.cells[1] == ["a", "b", "c"])
		let output = try DocxFile(url: url).markdown()
		#expect(output.contains("Merged"))
		#expect(output.contains("Right"))
		#expect(output.contains("a") && output.contains("b") && output.contains("c"))
	}

	/// Builds a minimal `.docx` Zip with `[Content_Types].xml` and `word/document.xml`.
	private func makeDocx(documentXML: String) throws -> URL {
		let contentTypes = """
		<?xml version="1.0" encoding="UTF-8"?>
		<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
		<Default Extension="xml" ContentType="application/xml"/>\
		<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
		</Types>
		"""
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("docx-parse-\(UUID().uuidString).docx")
		try ZipContainerWriter.write([
			ZipContainerEntry(path: "[Content_Types].xml", data: Data(contentTypes.utf8)),
			ZipContainerEntry(path: "word/document.xml", data: Data(documentXML.utf8))
		], to: url)
		return url
	}
}
