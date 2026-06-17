//  ImageDecoder.swift
//  SwiftTextRender
//
//  Turns raster image bytes into a PDF Image XObject without decoding the
//  pixels — which keeps the engine dependency-free (no zlib/libjpeg):
//   • JPEG embeds verbatim with the DCTDecode filter.
//   • PNG (grayscale or truecolor, non-interlaced) embeds its raw IDAT stream
//     with FlateDecode and the PNG predictor, which PDF readers apply natively.
//  Unsupported variants (palette, alpha, interlaced) still report intrinsic
//  dimensions so layout can reserve space; the painter draws a placeholder.

import Foundation
import SwiftTextPDFWriter

/// A decoded image: its intrinsic pixel size and, when embeddable, the PDF
/// Image XObject to draw.
public struct DecodedImage {
	public let width: Int
	public let height: Int
	/// The Image XObject, or `nil` if the format can't be embedded yet.
	public let pdfStream: PDFStream?
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
					("Filter", "/DCTDecode"),
				])
				return DecodedImage(width: width, height: height, pdfStream: stream)
			}
			index += 2 + length
		}
		return nil
	}

	// MARK: - PNG

	private static func decodePNG(_ data: Data) -> DecodedImage? {
		let bytes = [UInt8](data)
		func be32(_ offset: Int) -> Int {
			Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
		}

		var index = 8
		var width = 0, height = 0, bitDepth = 8, colorType = 0, interlace = 0
		var sawIHDR = false
		var idat = Data()
		while index + 8 <= bytes.count {
			let length = be32(index)
			let type = String(bytes: bytes[index + 4 ..< index + 8], encoding: .ascii) ?? ""
			let dataStart = index + 8
			guard dataStart + length + 4 <= bytes.count else { break }
			switch type {
			case "IHDR":
				width = be32(dataStart)
				height = be32(dataStart + 4)
				bitDepth = Int(bytes[dataStart + 8])
				colorType = Int(bytes[dataStart + 9])
				interlace = Int(bytes[dataStart + 12])
				sawIHDR = true
			case "IDAT":
				idat.append(contentsOf: bytes[dataStart ..< dataStart + length])
			case "IEND":
				index = bytes.count
				continue
			default:
				break
			}
			index = dataStart + length + 4 // skip data and CRC
		}

		guard sawIHDR, width > 0, height > 0 else { return nil }

		let colors: Int
		let colorSpace: String
		switch colorType {
		case 0: colors = 1; colorSpace = "/DeviceGray"
		case 2: colors = 3; colorSpace = "/DeviceRGB"
		default:
			// Palette (3), grayscale+alpha (4) and truecolor+alpha (6) need extra
			// handling (palette/SMask); reserve space but don't embed yet.
			return DecodedImage(width: width, height: height, pdfStream: nil)
		}
		guard interlace == 0 else {
			return DecodedImage(width: width, height: height, pdfStream: nil)
		}

		let stream = PDFStream(stream: [idat], extra: [
			("Type", "/XObject"),
			("Subtype", "/Image"),
			("Width", width),
			("Height", height),
			("ColorSpace", colorSpace),
			("BitsPerComponent", bitDepth),
			("Filter", "/FlateDecode"),
			("DecodeParms", PDFDictionary([
				("Predictor", 15),
				("Colors", colors),
				("BitsPerComponent", bitDepth),
				("Columns", width),
			])),
		])
		return DecodedImage(width: width, height: height, pdfStream: stream)
	}
}
