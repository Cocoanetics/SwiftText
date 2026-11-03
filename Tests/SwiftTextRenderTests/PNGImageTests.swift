//  PNGImageTests.swift
//  SwiftTextRenderTests

import Foundation
import Testing
@testable import SwiftTextRender
@testable import SwiftTextPDFWriter

/// The in-house inflate, and the PNG variants that need it: anything with
/// transparency or interlacing, which PDF cannot take as PNG stores it. The
/// fixtures were written with Python's `zlib` and `struct`, so they check the
/// decoder against the reference encoder rather than against itself.
@Suite("PNG images")
struct PNGImageTests {

	// MARK: - Inflate

	@Test("Inflates a fixed-Huffman zlib stream")
	func inflatesFixedHuffman() throws {
		let stream = try #require(Data(base64Encoded: "eNoLLs9MKwlJrShRyMxLy0ksSS1WKM9ILFEI8HNXSEmFiOgpBI+qGlU1qmpU1aiqIa4KAPPJJLc="))
		let text = String(decoding: try Inflate.zlib(stream), as: UTF8.self)
		#expect(text == String(repeating: "SwiftText inflates what PNG deflates. ", count: 40))
	}

	@Test("Inflates stored blocks")
	func inflatesStoredBlocks() throws {
		// Two stored blocks: "Hello, " (not final) then "PNG" (final).
		var stream = Data([0x78, 0x01])
		for (text, isFinal) in [("Hello, ", false), ("PNG", true)] {
			let bytes = Array(text.utf8)
			stream.append(isFinal ? 1 : 0)
			stream.append(contentsOf: [UInt8(bytes.count & 0xFF), UInt8(bytes.count >> 8)])
			stream.append(contentsOf: [UInt8(~bytes.count & 0xFF), UInt8((~bytes.count >> 8) & 0xFF)])
			stream.append(contentsOf: bytes)
		}
		#expect(String(decoding: try Inflate.zlib(stream), as: UTF8.self) == "Hello, PNG")
	}

	@Test("Inflates what the PDF writer deflates")
	func roundTripsTheWritersDeflate() throws {
		var bytes: [UInt8] = []
		var seed: UInt32 = 0x1234_5678
		for index in 0 ..< 70_000 {
			// Runs of repeats (back-references, some past the 32 KiB window
			// boundary) mixed with pseudo-random literals.
			seed = seed &* 1_664_525 &+ 1_013_904_223
			bytes.append(index % 3 == 0 ? UInt8(truncatingIfNeeded: seed >> 24) : UInt8(index / 97 % 251))
		}
		#expect(try Inflate.zlib(Deflate.zlib(Data(bytes))) == bytes)
		#expect(try Inflate.zlib(Deflate.zlib(Data())) == [])
	}

	@Test("Corrupt or oversized streams throw instead of crashing")
	func rejectsCorruptStreams() throws {
		let stream = try #require(Data(base64Encoded: "eNoLLs9MKwlJrShRyMxLy0ksSS1WKM9ILFEI8HNXSEmFiOgpBI+qGlU1qmpU1aiqIa4KAPPJJLc="))
		#expect(throws: Inflate.Failure.invalidHeader) { try Inflate.zlib(Data([0x00, 0x00])) }
		#expect(throws: Inflate.Failure.truncated) { try Inflate.zlib(stream.prefix(20)) }
		#expect(throws: Inflate.Failure.outputLimitExceeded) { try Inflate.zlib(stream, limit: 100) }
	}

	// MARK: - PNG

	@Test("An RGBA PNG embeds its colour with the alpha channel as a soft mask")
	func rgbaBecomesColorAndSoftMask() throws {
		let image = try decode("iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFUlEQVR42mP4z8DwHwhB4H/DfyAAAD1XCHkixQx7AAAAAElFTkSuQmCC")
		#expect(samples(image.pdfStream) == [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
		#expect(samples(image.softMask) == [255, 0, 128, 255])
		#expect(serialized(image.pdfStream).contains("/ColorSpace /DeviceRGB"))
		#expect(serialized(image.softMask).contains("/ColorSpace /DeviceGray"))
	}

	@Test("A palette PNG with tRNS keeps its indexed scanlines and gains a soft mask")
	func paletteTransparencyBecomesSoftMask() throws {
		let image = try decode("iVBORw0KGgoAAAANSUhEUgAAAAQAAAABCAMAAADO4v//AAAADFBMVEX/AAAA/wAAAP///wDWAo97AAAAAnRSTlMAgJsrThgAAAANSURBVHjaY2BgZGIGAAAPAAdb0It9AAAAAElFTkSuQmCC")
		let color = serialized(image.pdfStream)
		#expect(color.contains("/Indexed /DeviceRGB 3 <ff000000ff000000ffffff00>"))
		#expect(color.contains("/Predictor 15"))
		// Entries past the end of tRNS are opaque.
		#expect(samples(image.softMask) == [0, 128, 255, 255])
	}

	@Test("An opaque palette PNG embeds without a soft mask")
	func opaquePaletteIsIndexed() throws {
		let image = try decode("iVBORw0KGgoAAAANSUhEUgAAAAQAAAABCAMAAADO4v//AAAADFBMVEX/AAAA/wAAAP///wDWAo97AAAADUlEQVR42mNgYGRiBgAADwAHW9CLfQAAAABJRU5ErkJggg==")
		#expect(serialized(image.pdfStream).contains("/Indexed /DeviceRGB 3"))
		#expect(image.softMask == nil)
	}

	@Test("Sub-byte palette indices are unpacked for the mask")
	func twoBitPaletteMask() throws {
		let image = try decode("iVBORw0KGgoAAAANSUhEUgAAAAgAAAABAgMAAACebgfQAAAADFBMVEUKFB4oMjxGUFpkbnjGSHffAAAABHRSTlP/AP9AiG7ciQAAAAtJREFUeNpjkH4CAAEdAQBuU/eeAAAAAElFTkSuQmCC")
		// Indices 0 1 2 3 3 2 1 0 with tRNS alphas 255 0 255 64.
		#expect(samples(image.softMask) == [255, 0, 255, 64, 64, 255, 0, 255])
		#expect(serialized(image.pdfStream).contains("/BitsPerComponent 2"))
	}

	@Test("Grayscale with alpha and 16-bit RGBA split into colour and mask")
	func grayAlphaAndSixteenBit() throws {
		let grayAlpha = try decode("iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAQAAABeK7cBAAAADUlEQVR42mM48d+ICwAGkAIExDSo4wAAAABJRU5ErkJggg==")
		#expect(samples(grayAlpha.pdfStream) == [200, 50])
		#expect(samples(grayAlpha.softMask) == [255, 10])

		let deep = try decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABEAYAAABPhRjKAAAAEUlEQVR42mMQMgmrmLWngQEAC/0C63TvI8QAAAAASUVORK5CYII=")
		#expect(samples(deep.pdfStream) == [0x12, 0x56, 0x9A])
		#expect(samples(deep.softMask) == [0x80])
	}

	@Test("A truecolor tRNS colour key becomes a PDF /Mask without decoding")
	func colorKeyBecomesMask() throws {
		let image = try decode("iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAABnRSTlMACQAJAAkVu+bLAAAAD0lEQVR42mNgZGLm5OQEAABZACK7xXE7AAAAAElFTkSuQmCC")
		#expect(serialized(image.pdfStream).contains("/Mask [9 9 9 9 9 9]"))
		#expect(image.softMask == nil)
	}

	@Test("An interlaced PNG is reassembled from its seven passes")
	func adam7Interlacing() throws {
		let image = try decode("iVBORw0KGgoAAAANSUhEUgAAAAMAAAADCAYAAAEhL4UpAAAALklEQVR42gXBgQAAAAgEsYMIIogggggiiIfI9NsATGaa3fXdmYgASVBVdLdnhgccDQ1sX+OFFgAAAABJRU5ErkJggg==")
		var gray: [UInt8] = []
		var alpha: [UInt8] = []
		for index in 0 ..< 9 {
			let level = UInt8(index * 20)
			gray += [level, level, level]
			alpha.append(index % 2 == 0 ? 255 : 0)
		}
		#expect(samples(image.pdfStream) == gray)
		#expect(samples(image.softMask) == alpha)
	}

	@Test("Paeth-filtered scanlines in a dynamic-Huffman stream decode exactly")
	func paethFilteredGradient() throws {
		let image = try decode([
			"iVBORw0KGgoAAAANSUhEUgAAADAAAAAgCAYAAABU1PscAAABfElEQVR42tWWCU+DMBSAqzLnfTDkHEdEdAvZ/P//TreU5aXQ9r22",
			"TLvkC+07WL68EgjY72/BWOArAVuygLELbwECl14iCFx5x4RA4BUSgYU3KASuvUAjsPxn9KMYQuDmD+jQtUiB2xlprPoJAncOKZ3d",
			"iyhwb0Fu2T+NgcADkdSgB8u3qcAjghhZR6EfxSwEniREipwJG2XeUuBZYDURM6FD1zoQeOGEYG1KS+5xJPBqQWPV70Ag5DcLDagN",
			"+w7sj1dLgRWYQMj3GEpCLaQfxSwEIuEIDQKRgkKTl7GV5hw+A1DgbYJcElfxpa0xFIgRAjEgE/Y6OnTtjBM4/EHCPyUSJC2hNjH9",
			"lEgJAimBd0Lt7rSecQIZmECmoNHkIf0oRhTIkQK5cIQyHhOpJXGRrTQ3wwSKiWdgECgAlbCXsVHmz/QQQ4E1f5GtNXwiatYUgRIh",
			"UCIESgQdomZ/vJ55AhWYQCXhQ5Eb2J3WDgVqjUAtHKGKxyDtRAzSj2I/ipJk7GgQD9MAAAAASUVORK5CYII="
		].joined())
		var expected: [UInt8] = []
		for y in 0 ..< 32 {
			for x in 0 ..< 48 { expected.append(UInt8((x + y) * 4 % 256)) }
		}
		#expect(samples(image.softMask) == expected)
		#expect(image.width == 48 && image.height == 32)
	}

	@Test("A transparent PNG renders as an image XObject drawn through its soft mask")
	func softMaskIsWrittenToThePDF() async throws {
		let uri = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFUlEQVR42mP4z8DwHwhB4H/DfyAAAD1XCHkixQx7AAAAAElFTkSuQmCC"
		var warnings: [String] = []
		let pdf = try await HTMLRenderer.renderPDF(
			html: "<img src=\"\(uri)\" style=\"width:20px\">",
			options: RenderOptions(compressStreams: false)) { warnings.append($0) }
		let text = String(decoding: pdf, as: UTF8.self)
		#expect(warnings.isEmpty)
		#expect(text.contains("/SMask "))
		#expect(!text.contains("0.9 0.9 0.9 rg")) // no placeholder
	}

	// MARK: - Helpers

	private func decode(_ base64: String) throws -> DecodedImage {
		let data = try #require(Data(base64Encoded: base64))
		let image = try #require(ImageDecoder.decode(data))
		try #require(image.pdfStream != nil)
		return image
	}

	/// The unencoded samples of an image stream built from decoded pixels.
	private func samples(_ stream: PDFStream?) -> [UInt8]? {
		(stream?.stream.first as? Data).map { [UInt8]($0) }
	}

	private func serialized(_ stream: PDFStream?) -> String {
		stream.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
	}
}
