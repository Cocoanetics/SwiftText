//  ImageDecoder.swift
//  SwiftTextRender
//
//  Turns raster image bytes into a PDF Image XObject, decoding pixels only
//  where PDF cannot take the file's own encoding — which keeps the engine
//  dependency-free (no zlib/libjpeg):
//   • JPEG embeds verbatim with the DCTDecode filter.
//   • PNG embeds its raw IDAT stream with FlateDecode and the PNG predictor,
//     which PDF readers apply natively; transparency and interlacing are
//     unpacked by `PNGImage` into colour plus a soft mask.
//  Unsupported formats still report intrinsic dimensions where they can so
//  layout can reserve space; the painter draws a placeholder.

import Foundation
import SwiftTextPDFWriter

/// A decoded image: its intrinsic pixel size and, when embeddable, the PDF
/// Image XObject to draw.
public struct DecodedImage {
	public let width: Int
	public let height: Int
	/// The Image XObject, or `nil` if the format can't be embedded yet.
	public let pdfStream: PDFStream?
	/// The alpha channel as a grayscale Image XObject — the `/SMask` the image
	/// is drawn through — or `nil` when the image is opaque.
	public let softMask: PDFStream?

	init(width: Int, height: Int, pdfStream: PDFStream?, softMask: PDFStream? = nil) {
		self.width = width
		self.height = height
		self.pdfStream = pdfStream
		self.softMask = softMask
	}
}

public enum ImageDecoder {

	/// Decode an image from a `data:` URI (base64 or percent-encoded).
	public static func decode(dataURI: String) -> DecodedImage? {
		guard dataURI.hasPrefix("data:"), let comma = dataURI.firstIndex(of: ",") else { return nil }
		let meta = dataURI[dataURI.index(dataURI.startIndex, offsetBy: 5) ..< comma]
		let payload = String(dataURI[dataURI.index(after: comma)...])
		let bytes: Data
		if meta.contains("base64") {
			let trimmed = payload.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "")
			guard let decoded = Data(base64Encoded: trimmed) else { return nil }
			bytes = decoded
		} else {
			bytes = Data((payload.removingPercentEncoding ?? payload).utf8)
		}
		return decode(bytes)
	}

	/// Decode an image from raw file bytes (JPEG or PNG).
	public static func decode(_ data: Data) -> DecodedImage? {
		let header = [UInt8](data.prefix(8))
		if header.count >= 3, header[0] == 0xFF, header[1] == 0xD8, header[2] == 0xFF {
			return decodeJPEG(data)
		}
		if header.count >= 8, header[0] == 0x89, header[1] == 0x50, header[2] == 0x4E, header[3] == 0x47 {
			return decodePNG(data)
		}
		return nil
	}

	// MARK: - JPEG

	private static func decodeJPEG(_ data: Data) -> DecodedImage? {
		let bytes = [UInt8](data)
		var index = 2
		while index + 9 < bytes.count {
			guard bytes[index] == 0xFF else { index += 1; continue }
			let marker = bytes[index + 1]
			// Standalone markers without a length.
			if marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01 {
				index += 2
				continue
			}
			let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
			let isSOF = (marker >= 0xC0 && marker <= 0xCF) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
			if isSOF {
				let height = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
				let width = Int(bytes[index + 7]) << 8 | Int(bytes[index + 8])
				let components = Int(bytes[index + 9])
				let colorSpace: String
				switch components {
				case 1: colorSpace = "/DeviceGray"
				case 4: colorSpace = "/DeviceCMYK"
				default: colorSpace = "/DeviceRGB"
				}
				let stream = PDFStream(stream: [data], extra: [
					("Type", "/XObject"),
					("Subtype", "/Image"),
					("Width", width),
					("Height", height),
					("ColorSpace", colorSpace),
					("BitsPerComponent", 8),
					("Filter", "/DCTDecode")
				])
				return DecodedImage(width: width, height: height, pdfStream: stream)
			}
			index += 2 + length
		}
		return nil
	}

	// MARK: - PNG

	private static func decodePNG(_ data: Data) -> DecodedImage? {
		PNGImage(data)?.decodedImage()
	}
}
