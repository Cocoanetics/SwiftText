import Foundation
import Testing
import ZIPFoundation

@testable import SwiftTextDOCX

@Suite("DOCX footnotes")
struct DocxFootnoteTests {
	@Test("Footnote references become [^N], numbered in reference order, with definitions")
	func readsFootnotes() throws {
		let documentXML = """
		<?xml version="1.0" encoding="UTF-8"?>
		<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p>\
		<w:r><w:t xml:space="preserve">First claim</w:t></w:r>\
		<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteReference w:id="2"/></w:r>\
		<w:r><w:t xml:space="preserve"> and second</w:t></w:r>\
		<w:r><w:footnoteReference w:id="3"/></w:r>\
		<w:r><w:t>.</w:t></w:r>\
		</w:p></w:body></w:document>
		"""
		// Footnote ids need not be sequential, and the separator/continuation
		// pseudo-footnotes must be ignored.
		let footnotesXML = """
		<?xml version="1.0" encoding="UTF-8"?>
		<w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
		<w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>\
		<w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>\
		<w:footnote w:id="2"><w:p><w:r><w:t>See Smith 2020, p. 5.</w:t></w:r></w:p></w:footnote>\
		<w:footnote w:id="3"><w:p><w:r><w:t>Ibid.</w:t></w:r></w:p></w:footnote>\
		</w:footnotes>
		"""
		let url = try makeDocx(parts: [
			"word/document.xml": documentXML,
			"word/footnotes.xml": footnotesXML
		])
		defer { try? FileManager.default.removeItem(at: url) }
		#expect(try DocxFile(url: url).markdown() == """
		First claim[^1] and second[^2].

		[^1]: See Smith 2020, p. 5.
		[^2]: Ibid.
		""")
	}

	/// Builds a minimal `.docx` Zip from the given part paths/contents.
	private func makeDocx(parts: [String: String]) throws -> URL {
		let build = FileManager.default.temporaryDirectory
			.appendingPathComponent("docx-build-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: build) }
		let contentTypes = """
		<?xml version="1.0" encoding="UTF-8"?>
		<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
		<Default Extension="xml" ContentType="application/xml"/>\
		<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
		</Types>
		"""
		var all = parts
		all["[Content_Types].xml"] = contentTypes
		for (path, contents) in all {
			let fileURL = build.appendingPathComponent(path)
			try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
			try Data(contents.utf8).write(to: fileURL)
		}
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("footnotes-\(UUID().uuidString).docx")
		try FileManager.default.zipItem(at: build, to: url, shouldKeepParent: false, compressionMethod: .deflate)
		return url
	}
}
