import Foundation
import SwiftTextDOCX
import Testing
import ZIPFoundation

@Suite("DOCX footnote writer")
struct DocxFootnoteWriterTests {

	@Test("Markdown footnotes become a native word/footnotes.xml part with a w:footnoteReference")
	func writesNativeFootnotes() throws {
		let markdown = """
		Body text[^1] here, with a note.

		[^1]: The footnote body text.
		"""

		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("fn-writer-\(UUID().uuidString).docx")
		defer { try? FileManager.default.removeItem(at: url) }

		try MarkdownToDocx.convert(markdown, to: url)

		let archive = try #require(Archive(url: url, accessMode: .read))

		func part(_ path: String) throws -> String {
			let entry = try #require(archive[path], "missing part \(path)")
			var data = Data()
			_ = try archive.extract(entry) { data.append($0) }
			return String(decoding: data, as: UTF8.self)
		}

		// The footnotes part exists and holds the note body plus the required
		// separator / continuationSeparator pseudo-footnotes.
		let footnotes = try part("word/footnotes.xml")
		#expect(footnotes.contains("The footnote body text."))
		#expect(footnotes.contains("w:type=\"separator\""))
		#expect(footnotes.contains("w:type=\"continuationSeparator\""))
		#expect(footnotes.contains("<w:footnote w:id=\"1\">"))
		#expect(footnotes.contains("<w:footnoteRef/>"))

		// The body has a real footnote reference run (superscript style + id).
		let document = try part("word/document.xml")
		#expect(document.contains("<w:footnoteReference w:id=\"1\"/>"))
		#expect(document.contains("<w:rStyle w:val=\"FootnoteReference\"/>"))
		// The literal definition/reference markup must not leak as plain text.
		#expect(!document.contains("[^1]"))

		// The part is registered in both the content types and the document rels.
		let contentTypes = try part("[Content_Types].xml")
		#expect(contentTypes.contains("/word/footnotes.xml"))
		#expect(contentTypes.contains("wordprocessingml.footnotes+xml"))

		let rels = try part("word/_rels/document.xml.rels")
		#expect(rels.contains("relationships/footnotes"))
		#expect(rels.contains("Target=\"footnotes.xml\""))

		// The styles required to render the footnote are present.
		let styles = try part("word/styles.xml")
		#expect(styles.contains("w:styleId=\"FootnoteText\""))
		#expect(styles.contains("w:styleId=\"FootnoteReference\""))
		#expect(styles.contains("<w:vertAlign w:val=\"superscript\"/>"))
	}

	@Test("Written footnotes round-trip back through the DOCX reader")
	func footnotesRoundTrip() throws {
		let markdown = """
		First claim[^a] and a second[^b].

		[^a]: See the appendix.
		[^b]: Ibid.
		"""

		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("fn-roundtrip-\(UUID().uuidString).docx")
		defer { try? FileManager.default.removeItem(at: url) }

		try MarkdownToDocx.convert(markdown, to: url)

		// The reader renumbers in reference order, so [^a]/[^b] come back as
		// [^1]/[^2] with their definitions collected at the end.
		#expect(try DocxFile(url: url).markdown() == """
		First claim[^1] and a second[^2].

		[^1]: See the appendix.
		[^2]: Ibid.
		""")
	}

	@Test("A document without footnotes emits no footnotes part")
	func noFootnotesNoPart() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("fn-none-\(UUID().uuidString).docx")
		defer { try? FileManager.default.removeItem(at: url) }

		try MarkdownToDocx.convert("Just a plain paragraph.", to: url)

		let archive = try #require(Archive(url: url, accessMode: .read))
		#expect(archive["word/footnotes.xml"] == nil)

		var data = Data()
		let entry = try #require(archive["[Content_Types].xml"])
		_ = try archive.extract(entry) { data.append($0) }
		#expect(!String(decoding: data, as: UTF8.self).contains("footnotes"))
	}

	@Test("A footnote reference inside a table header cell is rendered, not dropped")
	func tableHeaderFootnoteRenders() throws {
		let markdown = """
		| Metric[^h] | Value |
		| --- | --- |
		| Speed | Fast |

		[^h]: Measured on the test rig.
		"""

		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("fn-thead-\(UUID().uuidString).docx")
		defer { try? FileManager.default.removeItem(at: url) }

		try MarkdownToDocx.convert(markdown, to: url)

		let archive = try #require(Archive(url: url, accessMode: .read))
		// The only reference is in the header cell, so its presence proves the
		// header path renders footnote runs (it now goes through renderRuns).
		#expect(try part("word/document.xml", from: archive).contains("<w:footnoteReference w:id=\"1\"/>"))
		// And the matching note body is emitted — no orphaned footnote.
		#expect(try part("word/footnotes.xml", from: archive).contains("Measured on the test rig."))
	}

	@Test("parseBlocks leaves footnotes as literal text — the low-level path emits no orphan references")
	func parseBlocksKeepsFootnotesLiteral() throws {
		// A caller using the documented low-level flow assigns parseBlocks output
		// straight to DocxWriter.blocks. Since that path can't carry footnote
		// bodies, it must not emit footnote-reference runs (which would be orphans).
		let writer = DocxWriter()
		writer.blocks = MarkdownToDocx.parseBlocks("See note[^1].\n\n[^1]: The note.")

		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("fn-parseblocks-\(UUID().uuidString).docx")
		defer { try? FileManager.default.removeItem(at: url) }
		try writer.write(to: url)

		let archive = try #require(Archive(url: url, accessMode: .read))
		#expect(archive["word/footnotes.xml"] == nil)
		let document = try part("word/document.xml", from: archive)
		#expect(!document.contains("<w:footnoteReference"))
		#expect(document.contains("[^1]"))  // reference stays literal
	}

	/// Reads a part out of a `.docx` archive as a UTF-8 string.
	private func part(_ path: String, from archive: Archive) throws -> String {
		let entry = try #require(archive[path], "missing part \(path)")
		var data = Data()
		_ = try archive.extract(entry) { data.append($0) }
		return String(decoding: data, as: UTF8.self)
	}
}
