//  PDFWriterTests.swift
//  SwiftTextPDFWriterTests

import Testing
import Foundation
@testable import SwiftTextPDFWriter

#if canImport(PDFKit)
import PDFKit
#endif

#if canImport(Compression)
import Compression

/// Inflate a raw DEFLATE payload (no zlib wrapper). Apple's `COMPRESSION_ZLIB`
/// is RFC 1951 raw DEFLATE, so the caller strips the 2-byte header / 4-byte
/// Adler-32 trailer from a zlib stream first.
private func inflateRawDeflate(_ data: Data, expectedSize: Int) -> Data? {
	let capacity = max(expectedSize, 64)
	let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
	defer { destination.deallocate() }
	let decoded = data.withUnsafeBytes { raw -> Int in
		guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
		return compression_decode_buffer(destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
	}
	guard decoded > 0 else { return nil }
	return Data(bytes: destination, count: decoded)
}

/// Inflate a full zlib stream (as produced by `Deflate.zlib`) by stripping its
/// wrapper and decoding the DEFLATE body.
private func inflateZlib(_ zlib: Data, expectedSize: Int) -> Data? {
	guard zlib.count > 6 else { return nil }
	let body = Data(zlib.dropFirst(2).dropLast(4))
	return inflateRawDeflate(body, expectedSize: expectedSize)
}
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

	// MARK: - FlateDecode compression

	/// Extract the raw payload between the `stream`/`endstream` keywords.
	private func streamBody(of stream: PDFStream) -> Data {
		let data = stream.data
		let start = data.range(of: Data("stream\n".utf8))!.upperBound
		let end = data.range(of: Data("\nendstream".utf8), options: .backwards)!.lowerBound
		return data.subdata(in: start ..< end)
	}

	@Test("Deflate produces a valid zlib stream that round-trips")
	func deflateRoundTrips() {
		// Repetitive content, like a real content stream, compresses well.
		var content = Data()
		for index in 0 ..< 500 {
			content.append(Data("BT /F1 12 Tf 72 \(720 - index) Td (Hello, world) Tj ET\n".utf8))
		}
		let zlib = Deflate.zlib(content)
		#expect(zlib.count < content.count / 4) // repetitive text deflates hard
		#expect(zlib.first == 0x78)             // zlib CMF header

		#if canImport(Compression)
		#expect(inflateZlib(zlib, expectedSize: content.count) == content)
		#endif
	}

	@Test("Deflate handles empty and tiny input")
	func deflateEdgeCases() {
		// Empty input still yields a well-formed zlib stream: 2-byte header, a
		// 2-byte final fixed block (just the end-of-block code), Adler-32 of the
		// empty string (== 1). (The Apple inflate helper can't confirm a
		// zero-length result — it returns 0 for both empty output and errors —
		// so assert the exact bytes instead.)
		let empty = Deflate.zlib(Data())
		#expect(empty == Data([0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]))

		let tiny = Deflate.zlib(Data("hi".utf8))
		#expect(tiny.first == 0x78)
		#if canImport(Compression)
		#expect(inflateZlib(tiny, expectedSize: 16) == Data("hi".utf8))
		#endif
	}

	@Test("Deflate round-trips binary data (all byte values)")
	func deflateBinary() {
		var content = Data()
		for round in 0 ..< 40 {
			for byte in 0 ... 255 { content.append(UInt8((byte + round) & 0xFF)) }
		}
		let zlib = Deflate.zlib(content)
		#expect(zlib.first == 0x78)
		#if canImport(Compression)
		#expect(inflateZlib(zlib, expectedSize: content.count) == content)
		#endif
	}

	@Test("An opted-in stream is emitted with /FlateDecode and a correct length")
	func streamCompresses() {
		let stream = PDFStream()
		stream.compressed = true
		stream.beginText()
		for index in 0 ..< 300 {
			stream.setFontSize("F1", 12)
			stream.moveTextTo(72, Double(720 - index))
			stream.showTextString("The quick brown fox jumps over the lazy dog")
		}
		stream.endText()

		let data = stream.data
		let text = String(decoding: data, as: UTF8.self)
		#expect(text.contains("/Filter /FlateDecode"))

		let body = streamBody(of: stream)
		#expect(text.contains("/Length \(body.count)")) // declared length is the compressed length

		// Much smaller than the same stream left uncompressed.
		let uncompressed = PDFStream(stream: stream.stream)
		#expect(body.count < uncompressed.data.count / 3)
		#expect(body.first == 0x78) // the payload really is a zlib stream

		#if canImport(Compression)
		// Decompressing reproduces the original operator bytes.
		let inflated = inflateZlib(body, expectedSize: uncompressed.data.count)
		#expect(inflated != nil)
		#expect(String(decoding: inflated ?? Data(), as: UTF8.self).contains("The quick brown fox"))
		#endif
	}

	@Test("Compression is skipped when a filter is already declared")
	func streamSkipsWhenFiltered() {
		// A pre-encoded (e.g. DCTDecode) stream must not be double-filtered.
		let payload = Data(repeating: 0x41, count: 4000)
		let stream = PDFStream(stream: [payload], extra: [("Filter", "/DCTDecode")])
		stream.compressed = true
		let data = stream.data
		let text = String(decoding: data, as: UTF8.self)
		#expect(text.contains("/Filter /DCTDecode"))
		#expect(!text.contains("/FlateDecode"))
		#expect(streamBody(of: stream) == payload) // payload untouched
	}

	@Test("Compression is skipped when it would not shrink the payload")
	func streamSkipsWhenNotSmaller() {
		// One byte cannot beat the ~7-byte zlib overhead, so it stays verbatim.
		let stream = PDFStream()
		stream.compressed = true
		stream.pushState() // emits the single-byte operator "q"
		let text = String(decoding: stream.data, as: UTF8.self)
		#expect(!text.contains("/FlateDecode"))
		#expect(text.contains("/Length 1"))
	}

	#if canImport(PDFKit)
	@Test("A PDF with a compressed content stream opens and text extracts")
	func compressedContentOpensInPDFKit() throws {
		let pdf = PDF()
		let content = PDFStream()
		content.compressed = true
		content.beginText()
		content.setFontSize("F1", 24)
		content.moveTextTo(72, 720)
		content.showTextString("Compressed Hello")
		content.endText()
		pdf.addObject(content)

		let font = PDFDictionary([("Type", "/Font"), ("Subtype", "/Type1"), ("BaseFont", "/Helvetica")])
		pdf.addObject(font)
		let resources = PDFDictionary([("Font", PDFDictionary([("F1", font.reference)]))])
		let page = PDFDictionary([
			("Type", "/Page"),
			("Parent", pdf.pages.reference),
			("MediaBox", PDFArray([0, 0, 612, 792])),
			("Contents", content.reference),
			("Resources", resources)
		])
		pdf.addPage(page)

		let document = try #require(PDFDocument(data: pdf.write()))
		#expect(document.pageCount == 1)
		#expect(document.page(at: 0)?.string?.contains("Compressed Hello") == true)
	}
	#endif

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
			("BaseFont", "/Helvetica")
		])
		pdf.addObject(font)

		let resources = PDFDictionary([
			("Font", PDFDictionary([("F1", font.reference)]))
		])
		let page = PDFDictionary([
			("Type", "/Page"),
			("Parent", pdf.pages.reference),
			("MediaBox", PDFArray([0, 0, 612, 792])),
			("Contents", content.reference),
			("Resources", resources)
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
