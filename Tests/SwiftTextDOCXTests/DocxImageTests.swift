import Foundation
@testable import SwiftTextDOCX
import Testing
import ZIPFoundation

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

	private static func text(of path: String, in archive: Archive) throws -> String {
		guard let entry = archive[path] else {
			throw DocxImageTestError.missingEntry(path)
		}
		var data = Data()
		_ = try archive.extract(entry) { data.append($0) }
		return String(decoding: data, as: UTF8.self)
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

		let archive = try #require(Archive(url: docxURL, accessMode: .read))

		// A media part for the embedded image exists, byte-identical to the source.
		let mediaPaths = archive.map(\.path).filter { $0.hasPrefix("word/media/") }
		#expect(mediaPaths.count == 1)
		let mediaEntry = try #require(archive[mediaPaths[0]])
		var mediaData = Data()
		_ = try archive.extract(mediaEntry) { mediaData.append($0) }
		#expect(mediaData == pngData)

		// document.xml carries the inline drawing referencing the embedded blip.
		let document = try Self.text(of: "word/document.xml", in: archive)
		#expect(document.contains("<w:drawing>"))
		#expect(document.contains("<a:blip r:embed="))
		#expect(document.contains("<pic:pic>"))
		// 1px × 9525 EMU/px for both dimensions.
		#expect(document.contains("cx=\"9525\""))
		#expect(document.contains("cy=\"9525\""))

		// Content type + relationship are wired up.
		let contentTypes = try Self.text(of: "[Content_Types].xml", in: archive)
		#expect(contentTypes.contains("<Default Extension=\"png\" ContentType=\"image/png\"/>"))

		let rels = try Self.text(of: "word/_rels/document.xml.rels", in: archive)
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

		let archive = try #require(Archive(url: docxURL, accessMode: .read))
		#expect(!archive.map(\.path).contains { $0.hasPrefix("word/media/") })

		let document = try Self.text(of: "word/document.xml", in: archive)
		#expect(!document.contains("<w:drawing>"))
		#expect(document.contains("banner alt"))
		#expect(document.contains("<w:i/>")) // italic placeholder
	}

	// A 32×16 JPEG header: SOI, then an SOF0 frame (precision 8, height 0x0010,
	// width 0x0020) followed by component padding. `fillBytes` extra 0xFF bytes are
	// inserted before the SOF marker (legal JPEG fill bytes).
	private static func jpegHeader(fillBytes: Int) -> [UInt8] {
		var bytes: [UInt8] = [0xFF, 0xD8] // SOI
		bytes.append(contentsOf: Array(repeating: 0xFF, count: fillBytes))
		bytes.append(contentsOf: [
			0xFF, 0xC0,       // SOF0 marker
			0x00, 0x0B,       // segment length (11)
			0x08,             // sample precision
			0x00, 0x10,       // height = 16
			0x00, 0x20,       // width = 32
			0x03, 0x01, 0x22, 0x00, // (truncated) component data
		])
		return bytes
	}

	@Test("JPEG dimensions parse without fill bytes")
	func jpegDimensionsBaseline() {
		let dims = DocxImageDimensions.dimensions(of: Self.jpegHeader(fillBytes: 0))
		#expect(dims?.width == 32)
		#expect(dims?.height == 16)
	}

	@Test("JPEG dimensions parse across leading 0xFF fill bytes")
	func jpegDimensionsWithFillBytes() {
		// Regression for Codex review on DocxImageDimensions: 0xFF fill bytes before
		// the SOF marker made the scanner apply segment-length math to a fill byte and
		// overshoot the frame, returning nil (→ alt-text fallback for a valid JPEG).
		for fill in 1...4 {
			let dims = DocxImageDimensions.dimensions(of: Self.jpegHeader(fillBytes: fill))
			#expect(dims?.width == 32, "fill=\(fill)")
			#expect(dims?.height == 16, "fill=\(fill)")
		}
	}

	@Test("Without a baseURL, images degrade to alt-text")
	func noBaseURLFallsBackToAltText() throws {
		let dir = try Self.makeTempDir()
		defer { try? FileManager.default.removeItem(at: dir) }

		let markdown = "![just text](tiny.png)\n"
		let docxURL = dir.appendingPathComponent("out.docx")
		try MarkdownToDocx.convert(markdown, to: docxURL) // no baseURL

		let archive = try #require(Archive(url: docxURL, accessMode: .read))
		#expect(!archive.map(\.path).contains { $0.hasPrefix("word/media/") })
		let document = try Self.text(of: "word/document.xml", in: archive)
		#expect(document.contains("just text"))
	}
}

private enum DocxImageTestError: Error {
	case missingEntry(String)
}
