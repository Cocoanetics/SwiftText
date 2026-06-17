import Foundation
import Testing

@testable import SwiftTextPages

@Suite("Embedded image extraction")
struct PagesImageTests {
	/// Builds a synthetic `.pages` package (directory bundle) with a minimal,
	/// parseable `Document.iwa` plus a `Data/` folder of media file names that
	/// mirror what Pages actually writes.
	private func makeBundle(dataFiles: [String]) throws -> URL {
		let storage = IWAWriter.varintField(1, 0) + IWAWriter.stringField(3, "Body text.")
		let documentIWA = IWAWriter.iwaFile([.init(identifier: 1, type: 2001, payload: storage)])

		let bundle = FileManager.default.temporaryDirectory
			.appendingPathComponent("images-\(UUID().uuidString).pages", isDirectory: true)
		let indexDir = bundle.appendingPathComponent("Index", isDirectory: true)
		let dataDir = bundle.appendingPathComponent("Data", isDirectory: true)
		try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
		try documentIWA.write(to: indexDir.appendingPathComponent("Document.iwa"))
		for name in dataFiles {
			try Data("x".utf8).write(to: dataDir.appendingPathComponent(name))
		}
		return bundle
	}

	private static let mediaFiles = [
		"image1-31.png",              // content
		"image1-small-32.png",        // downscaled preview -> skipped
		"PresetImageFill0-24.jpg",    // theme fill -> skipped
		"bullet_gbutton_gray-30.png", // list-bullet glyph -> skipped
		"pasted-image-16.png",        // content
		"pasted-image-21.png",        // content (distinct, shares base name)
		"pasted-image-small-17.png",  // downscaled preview -> skipped
	]

	@Test("Keeps content images, cleans names, and disambiguates collisions")
	func keepsOnlyContentImages() throws {
		let bundle = try makeBundle(dataFiles: PagesImageTests.mediaFiles)
		defer { try? FileManager.default.removeItem(at: bundle) }
		let outDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: outDir) }

		let urls = try PagesFile(url: bundle).extractImages(to: outDir)
		// Thumbnails (-small) and theme assets (PresetImageFill*, *bullet*) are
		// dropped; the two distinct "pasted-image"s are both kept under
		// collision-disambiguated names.
		#expect(Set(urls.map { $0.lastPathComponent }) == ["image1.png", "pasted-image.png", "pasted-image-1.png"])
		for url in urls {
			#expect(FileManager.default.fileExists(atPath: url.path))
		}
	}

	@Test("Includes thumbnails and theme assets under original names when asked")
	func includesEverythingOnRequest() throws {
		let bundle = try makeBundle(dataFiles: PagesImageTests.mediaFiles)
		defer { try? FileManager.default.removeItem(at: bundle) }
		let outDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: outDir) }

		let urls = try PagesFile(url: bundle).extractImages(to: outDir, includingThumbnailsAndAssets: true)
		#expect(Set(urls.map { $0.lastPathComponent }) == Set(PagesImageTests.mediaFiles))
	}

	/// Builds a synthetic document whose body anchors an inline image, exercising
	/// the full resolution chain: attachment run table → attachment → drawable →
	/// data reference → registry, and the consistency between the Markdown link
	/// and the extracted file name.
	@Test("Emits an inline image link resolving to the extracted file")
	func inlineImageReference() throws {
		// Data registry: a content image (data id 900) and its thumbnail (901),
		// nested as DataInfo sub-messages {1: id, 3: display, 4: disk}.
		func dataInfo(_ id: Int, _ display: String, _ disk: String) -> [UInt8] {
			IWAWriter.varintField(1, id) + IWAWriter.stringField(3, display) + IWAWriter.stringField(4, disk)
		}
		let registry = IWAWriter.bytesField(3, dataInfo(900, "photo.png", "photo-5.png"))
			+ IWAWriter.bytesField(3, dataInfo(901, "photo-small.png", "photo-small-6.png"))

		// Attachment (field 1 → drawable) and image drawable (field 11 → data id 900).
		let attachment = IWAWriter.bytesField(1, IWAWriter.varintField(1, 51))
		let drawable = IWAWriter.bytesField(11, IWAWriter.varintField(1, 900))

		// Body storage: text "AB<anchor>CD" (anchor at UTF-16 index 2) plus an
		// attachment run table entry {1: index, 2: {1: attachmentID}} in field 9.
		let runEntry = IWAWriter.varintField(1, 2) + IWAWriter.bytesField(2, IWAWriter.varintField(1, 50))
		let runTable = IWAWriter.bytesField(1, runEntry)
		let body = IWAWriter.varintField(1, 0)
			+ IWAWriter.stringField(3, "AB\u{FFFC}CD")
			+ IWAWriter.bytesField(9, runTable)

		let documentIWA = IWAWriter.iwaFile([
			.init(identifier: 2, type: 11006, payload: registry),
			.init(identifier: 10, type: 2001, payload: body),
			.init(identifier: 50, type: 2003, payload: attachment),
			.init(identifier: 51, type: 3005, payload: drawable),
		])

		let bundle = FileManager.default.temporaryDirectory
			.appendingPathComponent("inline-\(UUID().uuidString).pages", isDirectory: true)
		let indexDir = bundle.appendingPathComponent("Index", isDirectory: true)
		let dataDir = bundle.appendingPathComponent("Data", isDirectory: true)
		try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: bundle) }
		try documentIWA.write(to: indexDir.appendingPathComponent("Document.iwa"))
		try Data("img".utf8).write(to: dataDir.appendingPathComponent("photo-5.png"))
		try Data("thumb".utf8).write(to: dataDir.appendingPathComponent("photo-small-6.png"))

		let pages = try PagesFile(url: bundle)
		// Markdown places the image inline; plain text omits it.
		#expect(pages.markdown() == "AB![](photo.png)CD")
		#expect(pages.plainText() == "ABCD")

		// Extraction writes the content image under the same name the link uses,
		// and skips the thumbnail.
		let outDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: outDir) }
		let urls = try pages.extractImages(to: outDir)
		#expect(urls.map { $0.lastPathComponent } == ["photo.png"])
	}

	// MARK: - Embedding (MD → Pages)

	/// A tiny but valid 1×1 PNG.
	static let onePixelPNG = Data(base64Encoded:
		"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!

	@Test("A Markdown image embeds into the package and round-trips back out")
	func imageEmbedsAndExtracts() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("img-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		try PagesImageTests.onePixelPNG.write(to: dir.appendingPathComponent("pic.png"))
		let out = dir.appendingPathComponent("doc.pages")

		try MarkdownToPages.convert("# Title\n\n![a picture](pic.png)\n", to: out, baseURL: dir)

		// Embedded: a Data/ file carrying the exact image bytes.
		let dataEntries = try PagesContainer.entries(at: out, prefix: "Data/")
		let image = try #require(dataEntries.first { $0.path.hasSuffix(".png") })
		#expect(image.data == PagesImageTests.onePixelPNG)

		// Round-trips: the parser recovers an image reference and re-emits `![...]`.
		let file = try PagesFile(url: out)
		#expect(file.document.imageAssets.count == 1)
		#expect(file.markdown().contains("!["))

		// Extracts: the original bytes come back out to disk.
		let extracted = try file.extractImages(to: dir.appendingPathComponent("out"))
		#expect(extracted.count == 1)
		#expect(try Data(contentsOf: try #require(extracted.first)) == PagesImageTests.onePixelPNG)
	}

	@Test("A missing image falls back to alt text (no Data file, still opens)")
	func missingImageFallsBack() throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent("img-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let out = dir.appendingPathComponent("doc.pages")

		try MarkdownToPages.convert("![the alt text](nope.png)\n", to: out, baseURL: dir)

		#expect(try PagesContainer.entries(at: out, prefix: "Data/").isEmpty)
		#expect(try PagesFile(url: out).markdown().contains("the alt text"))
	}

	@Test("SHA-1 digest matches RFC 3174")
	func sha1Digest() {
		// Image dimension parsing now lives in SwiftTextCore.ImageDimensions (tested in
		// SwiftTextCoreTests). SHA-1 stays here — it's used only by the Pages writer.
		// SHA1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d
		let digest = SHA1.hash(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined()
		#expect(digest == "a9993e364706816aba3e25717850c26c9cd0d89d")
	}
}
