//
//  StderrQuietTests.swift
//  SwiftTextOCRTests
//

import Foundation
import Testing

#if canImport(PDFKit)
import CoreText
import PDFKit
import SwiftTextPDF

struct StderrQuietTests {
	@Test("Text-layer extraction writes nothing to stderr")
	func extractionIsQuiet() throws {
		let data = NSMutableData()
		var box = CGRect(x: 0, y: 0, width: 400, height: 200)
		let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
		let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
		context.beginPDFPage(nil)
		let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
		let attributed = NSAttributedString(string: "Hello world", attributes: [
			NSAttributedString.Key(kCTFontAttributeName as String): font
		])
		context.textPosition = CGPoint(x: 20, y: 100)
		CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
		context.endPDFPage()
		context.closePDF()
		let page = try #require(PDFDocument(data: data as Data)?.page(at: 0))

		let capture = FileManager.default.temporaryDirectory
			.appendingPathComponent("stderr-\(UUID().uuidString).txt")
		FileManager.default.createFile(atPath: capture.path, contents: nil)
		defer { try? FileManager.default.removeItem(at: capture) }

		fflush(stderr)
		let saved = dup(STDERR_FILENO)
		let fd = open(capture.path, O_WRONLY)
		dup2(fd, STDERR_FILENO)
		close(fd)
		let text = page.textLinesFromSelections()?.map(\.combinedText).joined(separator: " ")
		fflush(stderr)
		dup2(saved, STDERR_FILENO)
		close(saved)

		#expect(text == "Hello world")
		let noise = try String(contentsOf: capture, encoding: .utf8)
		#expect(noise.isEmpty, "stderr: \(noise)")
	}
}
#endif
