import Foundation
import Testing
import ZIPFoundation

@testable import SwiftTextDOCX

@Suite("DOCX strikethrough")
struct DocxStrikethroughTests {
	@Test("Reads w:strike runs as Markdown ~~, wrapping any emphasis")
	func readsStrikethrough() throws {
		let documentXML = """
		<?xml version="1.0" encoding="UTF-8"?>
		<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p>\
		<w:r><w:t xml:space="preserve">Normal </w:t></w:r>\
		<w:r><w:rPr><w:strike/></w:rPr><w:t>struck</w:t></w:r>\
		<w:r><w:t xml:space="preserve"> and </w:t></w:r>\
		<w:r><w:rPr><w:b/><w:strike/></w:rPr><w:t>bold-struck</w:t></w:r>\
		</w:p></w:body></w:document>
		"""
		let url = try makeDocx(documentXML: documentXML)
		defer { try? FileManager.default.removeItem(at: url) }
		#expect(try DocxFile(url: url).markdown() == "Normal ~~struck~~ and ~~**bold-struck**~~")
	}

	/// Builds a minimal `.docx` (a Zip with `[Content_Types].xml` and the given
	/// `word/document.xml`).
	private func makeDocx(documentXML: String) throws -> URL {
		let build = FileManager.default.temporaryDirectory
			.appendingPathComponent("docx-build-\(UUID().uuidString)", isDirectory: true)
		let wordDir = build.appendingPathComponent("word", isDirectory: true)
		try FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: build) }

		let contentTypes = """
		<?xml version="1.0" encoding="UTF-8"?>
		<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
		<Default Extension="xml" ContentType="application/xml"/>\
		<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
		</Types>
		"""
		try Data(contentTypes.utf8).write(to: build.appendingPathComponent("[Content_Types].xml"))
		try Data(documentXML.utf8).write(to: wordDir.appendingPathComponent("document.xml"))

		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("strike-\(UUID().uuidString).docx")
		try FileManager.default.zipItem(at: build, to: url, shouldKeepParent: false, compressionMethod: .deflate)
		return url
	}
}
