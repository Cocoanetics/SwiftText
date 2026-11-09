#if canImport(PDFKit) && canImport(CoreText)
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import SwiftTextHTML

@Suite("PDF text locator")
struct PDFTextLocatorTests {
	/// One page per string, each laid out in a rect narrow enough that the text wraps.
	private func makeDocument(_ pages: [String]) throws -> PDFDocument {
		let data = NSMutableData()
		let consumer = try #require(CGDataConsumer(data: data))
		var box = CGRect(x: 0, y: 0, width: 200, height: 300)
		let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
		let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
		for text in pages {
			context.beginPDFPage(nil)
			let attributed = NSAttributedString(string: text, attributes: [.font: font])
			let framesetter = CTFramesetterCreateWithAttributedString(attributed)
			let path = CGPath(rect: CGRect(x: 20, y: 20, width: 90, height: 260), transform: nil)
			CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), context)
			context.endPDFPage()
		}
		context.closePDF()
		return try #require(PDFDocument(data: data as Data))
	}

	@Test("a needle that wraps over lines is found on its page")
	func wrappedNeedle() throws {
		let document = try makeDocument(["Intro text", "Ein ziemlich langer Titel der umbricht"])
		let page = try #require(document.page(at: 1)?.string)
		try #require(page.contains("\n") || page.contains("\r"), "the fixture must wrap")
		#expect(document.findString("Ein ziemlich langer Titel", withOptions: []).isEmpty, "PDFKit alone does not find it")
		let found = try #require(PDFTextLocator(document: document).locate("Ein ziemlich langer Titel", occurrence: 0))
		#expect(found.pageIndex == 1)
		#expect(found.bounds.height > 0)
	}

	@Test("the n-th occurrence is counted across pages, ignoring case and hyphens")
	func occurrences() throws {
		let document = try makeDocument(["Kapitel eins", "KAPITEL eins", "Kapitel-eins zwei"])
		let locator = PDFTextLocator(document: document)
		#expect(locator.locate("kapitel eins", occurrence: 0)?.pageIndex == 0)
		#expect(locator.locate("kapitel eins", occurrence: 1)?.pageIndex == 1)
		#expect(locator.locate("kapitel eins", occurrence: 2)?.pageIndex == 2)
		#expect(locator.locate("kapitel eins", occurrence: 3) == nil)
	}

	@Test("text that is not there is not found")
	func missing() throws {
		let document = try makeDocument(["Nur ein Satz"])
		#expect(PDFTextLocator(document: document).locate("ganz anders", occurrence: 0) == nil)
		#expect(PDFTextLocator(document: document).locate("  - ", occurrence: 0) == nil)
	}

	@Test("compact removes whitespace and hyphens and lowercases")
	func compact() {
		#expect(PDFTextLocator.compact("Park-\nInson\u{00AD} Er kr") == "parkinsonerkr")
		// Case is folded per character, as the DOM side does, so a capital sigma never becomes a final one.
		#expect(PDFTextLocator.compact("ΟΣ") == "οσ")
	}
}
#endif
