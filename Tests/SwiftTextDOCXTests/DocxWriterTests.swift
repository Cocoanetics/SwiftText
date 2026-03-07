import Foundation
import SwiftTextDOCX
import Testing
import ZIPFoundation

@Suite("DOCX Writer")
struct DocxWriterTests {

	@Test("Generates valid DOCX archive from blocks")
	func writerCreatesValidArchive() throws {
		let writer = DocxWriter()
		writer.blocks = [
			.heading(level: 1, runs: [.init(text: "Test Heading")]),
			.paragraph(runs: [
				.init(text: "Normal text "),
				.init(text: "bold", bold: true),
				.init(text: " and "),
				.init(text: "italic", italic: true),
			]),
			.listItem(ordered: false, level: 0, runs: [.init(text: "Bullet")]),
			.listItem(ordered: true, level: 0, runs: [.init(text: "Numbered")]),
			.codeBlock(language: "swift", text: "let x = 42"),
			.horizontalRule,
		]

		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("writer-test-\(UUID().uuidString).docx")
		defer { try? FileManager.default.removeItem(at: url) }

		try writer.write(to: url)

		// Verify it's a valid ZIP with the expected OOXML parts
		let archive = try #require(Archive(url: url, accessMode: .read))
		let paths = archive.map(\.path)
		#expect(paths.contains("[Content_Types].xml"))
		#expect(paths.contains("word/document.xml"))
		#expect(paths.contains("word/styles.xml"))
		#expect(paths.contains("word/numbering.xml"))

		// Extract document.xml and verify content
		var documentData = Data()
		let entry = try #require(archive["word/document.xml"])
		_ = try archive.extract(entry) { documentData.append($0) }
		let xml = String(data: documentData, encoding: .utf8)!
		#expect(xml.contains("Test Heading"))
		#expect(xml.contains("<w:b/>"))
		#expect(xml.contains("<w:i/>"))
		#expect(xml.contains("let x = 42"))
	}

	@Test("MarkdownToDocx converts markdown to DOCX")
	func markdownConversion() throws {
		let markdown = """
		# Hello World

		This is **bold** and *italic* text with `code`.

		- Item A
		- Item B

		1. First
		2. Second

		```python
		print("hi")
		```

		> A quote

		---

		[Link](https://example.com)
		"""

		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("md-test-\(UUID().uuidString).docx")
		defer { try? FileManager.default.removeItem(at: url) }

		try MarkdownToDocx.convert(markdown, to: url)

		let archive = try #require(Archive(url: url, accessMode: .read))
		var documentData = Data()
		let entry = try #require(archive["word/document.xml"])
		_ = try archive.extract(entry) { documentData.append($0) }
		let xml = String(data: documentData, encoding: .utf8)!

		#expect(xml.contains("Hello World"))
		#expect(xml.contains("Heading1"))
		#expect(xml.contains("<w:b/>"))
		#expect(xml.contains("<w:i/>"))
		#expect(xml.contains("Courier New"))
		#expect(xml.contains("print(&quot;hi&quot;)"))
		#expect(xml.contains("rLink1"))
	}

	@Test("Inline parser handles mixed formatting")
	func inlineParser() {
		let runs = MarkdownToDocx.parseInline("Hello **bold** and *italic* with `code`")
		#expect(runs.count == 6)
		#expect(runs[0].text == "Hello ")
		#expect(runs[1].text == "bold")
		#expect(runs[1].bold == true)
		#expect(runs[2].text == " and ")
		#expect(runs[3].text == "italic")
		#expect(runs[3].italic == true)
		#expect(runs[4].text == " with ")
		#expect(runs[5].text == "code")
		#expect(runs[5].code == true)
	}

	@Test("Inline parser handles links")
	func inlineParserLinks() {
		let runs = MarkdownToDocx.parseInline("See [here](https://example.com) for details")
		#expect(runs.count == 3)
		#expect(runs[0].text == "See ")
		#expect(runs[1].text == "here")
		#expect(runs[1].link == "https://example.com")
		#expect(runs[2].text == " for details")
	}

	@Test("Inline parser handles bold+italic")
	func inlineParserBoldItalic() {
		let runs = MarkdownToDocx.parseInline("This is ***important***")
		#expect(runs.count == 2)
		#expect(runs[1].text == "important")
		#expect(runs[1].bold == true)
		#expect(runs[1].italic == true)
	}

	@Test("Block parser handles nested blockquotes")
	func blockParserBlockquotes() {
		let blocks = MarkdownToDocx.parseBlocks("> Quoted **text**")
		#expect(blocks.count == 1)
		if case .blockquote(let inner) = blocks[0] {
			#expect(inner.count == 1)
		} else {
			#expect(Bool(false), "Expected blockquote")
		}
	}
}
