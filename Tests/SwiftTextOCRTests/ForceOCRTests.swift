//
//  ForceOCRTests.swift
//  SwiftTextOCRTests
//

import Foundation
import Testing

#if canImport(Vision) && canImport(PDFKit)
import CoreText
import PDFKit
import Vision

@testable import SwiftTextOCR
import SwiftTextPDF

struct ForceOCRTests {
	@Test("Language hints split on commas, trim and drop repeats in order")
	func parsesLanguageHints() {
		#expect(RecognitionLanguages.parse(["de,en", " en-US ", "DE", ""]) == ["de", "en", "en-US"])
		#expect(RecognitionLanguages.parse([]).isEmpty)
	}

	@Test("A bare language code resolves to the supported identifier")
	func resolvesBareCodes() {
		let supported = ["en-US", "de-DE", "fr-FR"]
		#expect(RecognitionLanguages.resolve(["de", "en-US"], supported: supported) == ["de-DE", "en-US"])
		#expect(RecognitionLanguages.resolve(["xx"], supported: supported) == ["xx"])
	}

	@Test("Unmatched language codes are reported")
	func reportsUnsupportedCodes() {
		let supported = ["en-US", "de-DE"]
		#expect(RecognitionLanguages.unsupported(["de", "xx", "en-US"], supported: supported) == ["xx"])
		#expect(RecognitionLanguages.unsupported(["de,en"], supported: supported).isEmpty)
	}

	@Test("Language hints reach the recognition request")
	func hintsReachTheRequest() throws {
		let request = makeTextRecognitionRequest(languages: ["de,en"])
		let supported = try request.supportedRecognitionLanguages()
		#expect(request.recognitionLanguages == RecognitionLanguages.resolve(["de", "en"], supported: supported))
		#expect(request.recognitionLanguages.first?.hasPrefix("de") == true)
	}

	@Test("Without hints the request keeps Vision's default languages")
	func noHintsKeepsDefault() {
		let defaults = VNRecognizeTextRequest().recognitionLanguages
		#expect(makeTextRecognitionRequest(languages: []).recognitionLanguages == defaults)
	}

	@Test("Forcing OCR ignores a bogus embedded text layer")
	func forcedOCRIgnoresTextLayer() throws {
		let document = try Self.pageWithBogusTextLayer()
		let page = try #require(document.page(at: 0))

		let embedded = page.textLines().map(\.combinedText).joined(separator: " ")
		#expect(embedded.contains("BOGUS"))

		let forced = page.textLines(forceOCR: true, dpi: 300).map(\.combinedText).joined(separator: " ")
		#expect(!forced.contains("BOGUS"))
		// Hosted CI runners have no Vision text recogniser and return nothing;
		// wherever it does run, it must read what is actually drawn.
		if !forced.isEmpty {
			#expect(forced.uppercased().contains("INVOICE"))
		}
	}

	/// A page that shows "INVOICE" but whose text layer says "BOGUS": the layer
	/// is drawn fully transparent, as a scanner's layer sits invisibly over the image.
	private static func pageWithBogusTextLayer() throws -> PDFDocument {
		let data = NSMutableData()
		var box = CGRect(x: 0, y: 0, width: 400, height: 200)
		let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
		let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
		context.beginPDFPage(nil)

		func draw(_ text: String, alpha: CGFloat, y: CGFloat) {
			let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 56, nil)
			let color = CGColor(gray: 0, alpha: alpha)
			let attributed = NSAttributedString(string: text, attributes: [
				NSAttributedString.Key(kCTFontAttributeName as String): font,
				NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
			])
			context.textPosition = CGPoint(x: 20, y: y)
			CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
		}
		draw("INVOICE", alpha: 1, y: 120)
		draw("BOGUS", alpha: 0, y: 30)

		context.endPDFPage()
		context.closePDF()
		return try #require(PDFDocument(data: data as Data))
	}
}
#endif
