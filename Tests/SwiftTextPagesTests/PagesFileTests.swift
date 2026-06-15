import Foundation
import Testing

@testable import SwiftTextPages

@Suite("PagesFile integration")
struct PagesFileTests {
	@Test("Extracts body paragraphs from a real Pages document")
	func parsesRealDocument() throws {
		let url = try #require(
			Bundle.module.url(forResource: "Sample", withExtension: "pages")
		)
		let pages = try PagesFile(url: url)
		#expect(pages.plainTextParagraphs() == [
			"Sample Document Title",
			"This is the first body paragraph with some words.",
			"This is the second body paragraph.",
		])
	}

	@Test("Reports a clear error for a non-iWork archive")
	func rejectsNonIWorkArchive() throws {
		// A directory with no Index/ entries is not a modern Pages document.
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("not-pages-\(UUID().uuidString).pages", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		#expect(throws: PagesFileError.self) {
			_ = try PagesFile(url: directory)
		}
	}

	/// Builds a synthetic `.pages` package directory (no Zip, no Pages.app) whose
	/// body storage references a large-font paragraph style, then checks that the
	/// full pipeline — container → IWA → Snappy → Protobuf → document → heading
	/// inference — recovers the heading and body paragraphs.
	@Test("Infers a heading through the full decode pipeline")
	func headingThroughFullPipeline() throws {
		let headingStyleID = 100
		let bodyStyleID = 101
		let text = "Big Heading\nNormal paragraph one.\nNormal paragraph two."

		// Paragraph-style run table: heading style from index 0, body style from
		// index 12 (just past "Big Heading\n").
		let headingRef = IWAWriter.varintField(1, headingStyleID)
		let bodyRef = IWAWriter.varintField(1, bodyStyleID)
		let entry0 = IWAWriter.varintField(1, 0) + IWAWriter.bytesField(2, headingRef)
		let entry1 = IWAWriter.varintField(1, 12) + IWAWriter.bytesField(2, bodyRef)
		let runTable = IWAWriter.bytesField(1, entry0) + IWAWriter.bytesField(1, entry1)

		// StorageArchive: kind 0 (body), the text, and the run table.
		let storage = IWAWriter.varintField(1, 0)
			+ IWAWriter.stringField(3, text)
			+ IWAWriter.bytesField(5, runTable)

		// Two paragraph styles distinguished only by font size.
		let headingStyle = IWAWriter.bytesField(11, IWAWriter.varintField(1, 1) + IWAWriter.floatField(3, 28))
		let bodyStyle = IWAWriter.bytesField(11, IWAWriter.varintField(1, 0) + IWAWriter.floatField(3, 12))

		let documentIWA = IWAWriter.iwaFile([
			.init(identifier: 1, type: 2001, payload: storage),
		])
		let stylesheetIWA = IWAWriter.iwaFile([
			.init(identifier: headingStyleID, type: 2022, payload: headingStyle),
			.init(identifier: bodyStyleID, type: 2022, payload: bodyStyle),
		])

		let bundle = FileManager.default.temporaryDirectory
			.appendingPathComponent("synthetic-\(UUID().uuidString).pages", isDirectory: true)
		let indexDir = bundle.appendingPathComponent("Index", isDirectory: true)
		try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: bundle) }
		try documentIWA.write(to: indexDir.appendingPathComponent("Document.iwa"))
		try stylesheetIWA.write(to: indexDir.appendingPathComponent("DocumentStylesheet.iwa"))

		let pages = try PagesFile(url: bundle)
		#expect(pages.plainTextParagraphs() == [
			"Big Heading",
			"Normal paragraph one.",
			"Normal paragraph two.",
		])

		let markdown = pages.markdown()
		#expect(markdown.hasPrefix("# Big Heading"))
		#expect(markdown.contains("\n\nNormal paragraph one.\n\nNormal paragraph two."))
	}
}
