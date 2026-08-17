import Foundation
import SwiftTextDOCX
import Testing

@Suite("DOCX Images")
struct DocxImageTests {

	/// A real 1×1 RGB PNG (signature + IHDR + IDAT + IEND), 69 bytes.
	private static let tinyPNGBase64 =
		"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

	private static func makeTempDir() throws -> URL {
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("docx-image-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	@Test("Embeds a referenced PNG as an inline image")
	func embedsReferencedPNG() throws {
		let dir = try Self.makeTempDir()
		defer { try? FileManager.default.removeItem(at: dir) }

		let pngData = try #require(Data(base64Encoded: Self.tinyPNGBase64))
		try pngData.write(to: dir.appendingPathComponent("tiny.png"))

		let markdown = "# Title\n\n![A tiny dot](tiny.png)\n"
		let docxURL = dir.appendingPathComponent("out.docx")
		try MarkdownToDocx.convert(markdown, to: docxURL, baseURL: dir)

		let archive = try DocxArchive(contentsOf: docxURL)

		// A media part for the embedded image exists, byte-identical to the source.
		let mediaPaths = archive.paths.filter { $0.hasPrefix("word/media/") }
		#expect(mediaPaths.count == 1)
		#expect(try archive.data(mediaPaths[0]) == pngData)

		// document.xml carries the inline drawing referencing the embedded blip.
		let document = try archive.text("word/document.xml")
		#expect(document.contains("<w:drawing>"))
		#expect(document.contains("<a:blip r:embed="))
		#expect(document.contains("<pic:pic>"))
		// 1px × 9525 EMU/px for both dimensions.
		#expect(document.contains("cx=\"9525\""))
		#expect(document.contains("cy=\"9525\""))

		// Content type + relationship are wired up.
		let contentTypes = try archive.text("[Content_Types].xml")
		#expect(contentTypes.contains("<Default Extension=\"png\" ContentType=\"image/png\"/>"))

		let rels = try archive.text("word/_rels/document.xml.rels")
		#expect(rels.contains("/relationships/image"))
		#expect(rels.contains("Target=\"media/image1.png\""))
	}

	@Test("Falls back to alt-text when the image file is missing")
	func missingImageFallsBackToAltText() throws {
		let dir = try Self.makeTempDir()
		defer { try? FileManager.default.removeItem(at: dir) }

		let markdown = "![banner alt](does-not-exist.png)\n"
		let docxURL = dir.appendingPathComponent("out.docx")
		try MarkdownToDocx.convert(markdown, to: docxURL, baseURL: dir)

		let archive = try DocxArchive(contentsOf: docxURL)
		#expect(!archive.paths.contains { $0.hasPrefix("word/media/") })

		let document = try archive.text("word/document.xml")
		#expect(!document.contains("<w:drawing>"))
		#expect(document.contains("banner alt"))
		#expect(document.contains("<w:i/>")) // italic placeholder
	}

	@Test("Without a baseURL, images degrade to alt-text")
	func noBaseURLFallsBackToAltText() throws {
		let dir = try Self.makeTempDir()
		defer { try? FileManager.default.removeItem(at: dir) }

		let markdown = "![just text](tiny.png)\n"
		let docxURL = dir.appendingPathComponent("out.docx")
		try MarkdownToDocx.convert(markdown, to: docxURL) // no baseURL

		let archive = try DocxArchive(contentsOf: docxURL)
		#expect(!archive.paths.contains { $0.hasPrefix("word/media/") })
		let document = try archive.text("word/document.xml")
		#expect(document.contains("just text"))
	}
}
