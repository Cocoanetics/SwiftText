import Foundation
import Testing

@testable import SwiftTextPages

@Suite("Pages writing")
struct PagesWriterTests {
	@Test("Plain multi-paragraph text reads back through PagesFile")
	func plainTextRoundTrips() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-write-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }

		try PagesWriter().write(text: "First paragraph.\nSecond paragraph.", to: url)

		let document = try PagesFile(url: url)
		let text = document.plainText()
		#expect(text.contains("First paragraph."))
		#expect(text.contains("Second paragraph."))
	}

	@Test("Headings, inline styles, and lists round-trip through the reader")
	func structuredBodyRoundTrips() throws {
		// "Plain then bold then italic." — UTF-16 offsets: bold=[11,15), italic=[21,27).
		let paragraphs: [BodyParagraph] = [
			BodyParagraph(text: "Document Title", paragraphStyle: PagesStyleID.heading1),
			BodyParagraph(text: "Plain then bold then italic.", paragraphStyle: PagesStyleID.body, runs: [
				.init(start: 11, length: 4, style: InlineStyle(bold: true)),
				.init(start: 21, length: 6, style: InlineStyle(italic: true))
			]),
			BodyParagraph(text: "First bullet", paragraphStyle: PagesStyleID.body, listStyle: PagesStyleID.bulletList),
			BodyParagraph(text: "Second bullet", paragraphStyle: PagesStyleID.body, listStyle: PagesStyleID.bulletList)
		]

		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-styled-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		try PagesWriter().write(paragraphs: paragraphs, to: url)

		let markdown = try PagesFile(url: url).markdown()
		#expect(markdown.contains("Document Title"))
		#expect(markdown.contains("bold"))
		#expect(markdown.contains("italic"))
		#expect(markdown.contains("First bullet"))
	}
}
