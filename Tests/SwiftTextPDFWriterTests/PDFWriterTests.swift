//  PDFWriterTests.swift
//  SwiftTextPDFWriterTests

import Testing
import Foundation
@testable import SwiftTextPDFWriter

#if canImport(PDFKit)
import PDFKit
#endif

@Suite("PDF Writer")
struct PDFWriterTests {

	// MARK: - Value serialization

	@Test("Real numbers format like pydyf")
	func realFormatting() {
		#expect(formatPDFReal(2.0) == "2")
		#expect(formatPDFReal(2.5) == "2.5")
		#expect(formatPDFReal(0.1) == "0.1")
		#expect(formatPDFReal(100) == "100")
		#expect(formatPDFReal(-0.5) == "-0.5")
		#expect(formatPDFReal(1.0 / 3.0) == "0.333333")
		#expect(formatPDFReal(0) == "0")
		#expect(formatPDFReal(.nan) == "0")
	}

	@Test("Dictionaries serialize in insertion order")
	func dictionaryData() {
		let dict = PDFDictionary([("Type", "/Page"), ("Count", 3)])
		#expect(String(decoding: dict.data, as: UTF8.self) == "<</Type /Page/Count 3>>")
	}

	@Test("Dictionary subscript updates value but keeps position")
	func dictionaryUpdate() {
		let dict = PDFDictionary([("A", 1), ("B", 2)])
		dict["A"] = 9
		#expect(String(decoding: dict.data, as: UTF8.self) == "<</A 9/B 2>>")
	}

	@Test("Arrays serialize space-separated")
	func arrayData() {
		let array = PDFArray([0, 0, 595, 842])
		#expect(String(decoding: array.data, as: UTF8.self) == "[0 0 595 842]")
	}

	@Test("Literal strings escape parens and backslash")
	func stringEscaping() {
		let data = PDFString("a(b)c\\").data
		#expect(String(decoding: data, as: UTF8.self) == "(a\\(b\\)c\\\\)")
	}

	@Test("Non-ASCII strings use UTF-16BE hex with BOM")
	func stringHex() {
		let data = PDFString("é").data
		#expect(String(decoding: data, as: UTF8.self) == "<feff00e9>")
	}

	@Test("Indirect objects wrap their body")
	func indirectRepresentation() {
		let dict = PDFDictionary([("Type", "/Catalog")])
		dict.number = 2
		#expect(String(decoding: dict.indirect, as: UTF8.self) == "2 0 obj\n<</Type /Catalog>>\nendobj")
		#expect(String(decoding: dict.reference, as: UTF8.self) == "2 0 R")
	}

	@Test("Stream records its length")
	func streamLength() {
		let stream = PDFStream()
		stream.beginText()
		stream.endText()
		let text = String(decoding: stream.data, as: UTF8.self)
		// "BT\nET" is five bytes.
		#expect(text.contains("/Length 5"))
		#expect(text.contains("stream\nBT\nET\nendstream"))
	}

	// MARK: - Document assembly

	/// Build a minimal one-page PDF that shows text with the built-in Helvetica
	/// font (no font embedding required).
	private func makeHelloPDF() -> PDF {
		let pdf = PDF()

		let content = PDFStream()
		content.beginText()
		content.setFontSize("F1", 24)
		content.moveTextTo(72, 720)
		content.showTextString("Hello, PDF!")
		content.endText()
		pdf.addObject(content)

		let font = PDFDictionary([
			("Type", "/Font"),
			("Subtype", "/Type1"),
			("BaseFont", "/Helvetica"),
		])
		pdf.addObject(font)

		let resources = PDFDictionary([
			("Font", PDFDictionary([("F1", font.reference)])),
		])
		let page = PDFDictionary([
			("Type", "/Page"),
			("Parent", pdf.pages.reference),
			("MediaBox", PDFArray([0, 0, 612, 792])),
			("Contents", content.reference),
			("Resources", resources),
		])
		pdf.addPage(page)
		return pdf
	}

	@Test("Writes a structurally valid single-page PDF")
	func writesValidPDF() {
		let pdf = makeHelloPDF()
		let bytes = pdf.write()
		let text = String(decoding: bytes, as: UTF8.self)

		#expect(text.hasPrefix("%PDF-1.7\n"))
		#expect(text.contains("/Type /Catalog"))
		#expect(text.contains("/Type /Pages"))
		#expect(text.contains("/Type /Page"))
		#expect(text.contains("/Kids [5 0 R]"))
		#expect(text.contains("xref"))
		#expect(text.contains("trailer"))
		#expect(text.contains("/Root 2 0 R"))
		#expect(text.hasSuffix("%%EOF\n"))

		// startxref must point exactly at the "xref" keyword.
		let xref = pdf.xrefPosition
		let slice = bytes[xref ..< min(xref + 4, bytes.count)]
		#expect(String(decoding: slice, as: UTF8.self) == "xref")
	}

	@Test("write() is idempotent — serializing twice yields identical bytes")
	func idempotentWrite() {
		let pdf = makeHelloPDF()
		let first = pdf.write()
		let second = pdf.write()
		// Offsets must not accumulate across writes: the two outputs are equal,
		// and startxref in the second still points exactly at its "xref" keyword.
		#expect(first == second)
		let xref = pdf.xrefPosition
		let slice = second[xref ..< min(xref + 4, second.count)]
		#expect(String(decoding: slice, as: UTF8.self) == "xref")
	}

	@Test("Page count is tracked")
	func pageCount() {
		let pdf = makeHelloPDF()
		#expect(pdf.pages["Count"] as? Int == 1)
		#expect(pdf.pageReferences.count == 1)
	}

	#if canImport(PDFKit)
	@Test("Generated PDF opens in PDFKit")
	func opensInPDFKit() throws {
		let bytes = makeHelloPDF().write()
		let document = try #require(PDFDocument(data: bytes))
		#expect(document.pageCount == 1)
		#expect(document.page(at: 0)?.string?.contains("Hello, PDF!") == true)
	}
	#endif
}
