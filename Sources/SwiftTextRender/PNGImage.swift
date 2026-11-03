//  PNGImage.swift
//  SwiftTextRender
//
//  Embeds PNG images in a PDF. FlateDecode with the PNG predictor reads PNG's
//  own compressed scanlines, so an opaque grayscale, truecolor or palette image
//  embeds without touching its pixels. Transparency is the exception: PDF keeps
//  alpha in a separate soft-mask image, so an alpha channel — or a palette whose
//  entries carry alpha, as most logos do — is inflated, unfiltered and split
//  into colour and mask. Interlaced images go the same way.

import Foundation
import SwiftTextPDFWriter

struct PNGImage {
	let width: Int
	let height: Int
	let bitDepth: Int
	let colorType: Int
	let isInterlaced: Bool
	/// `PLTE`: red, green and blue for each palette entry.
	let palette: [UInt8]
	/// `tRNS`: an alpha per palette entry, or the one grayscale / RGB sample
	/// value that is fully transparent.
	let transparency: [UInt8]?
	/// The concatenated `IDAT` payload: a zlib stream of filtered scanlines.
	let pixelData: Data

	/// Larger images are laid out but not decoded, so a corrupt or hostile
	/// header cannot make the renderer allocate gigabytes.
	private static let maximumDecodedPixels = 50_000_000

	private enum Failure: Error {
		case truncated
		case unknownFilter
	}

	init?(_ data: Data) {
		let bytes = [UInt8](data)
		func be32(_ offset: Int) -> Int {
			Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
		}

		var width = 0, height = 0, bitDepth = 8, colorType = 0, interlace = 0
		var sawHeader = false
		var palette: [UInt8] = []
		var transparency: [UInt8]?
		var pixelData = Data()
		var index = 8
		chunks: while index + 8 <= bytes.count {
			let length = be32(index)
			let type = String(bytes: bytes[index + 4 ..< index + 8], encoding: .ascii) ?? ""
			let dataStart = index + 8
			guard length >= 0, dataStart + length + 4 <= bytes.count else { break }
			let payload = bytes[dataStart ..< dataStart + length]
			switch type {
			case "IHDR" where length >= 13:
				width = be32(dataStart)
				height = be32(dataStart + 4)
				bitDepth = Int(bytes[dataStart + 8])
				colorType = Int(bytes[dataStart + 9])
				interlace = Int(bytes[dataStart + 12])
				sawHeader = true
			case "PLTE":
				palette = Array(payload)
			case "tRNS":
				transparency = Array(payload)
			case "IDAT":
				pixelData.append(contentsOf: payload)
			case "IEND":
				break chunks
			default:
				break
			}
			index = dataStart + length + 4 // skip the data and its CRC
		}
		guard sawHeader, width > 0, height > 0 else { return nil }

		self.width = width
		self.height = height
		self.bitDepth = bitDepth
		self.colorType = colorType
		self.isInterlaced = interlace != 0
		self.palette = palette
		self.transparency = transparency
		self.pixelData = pixelData
	}

	/// The image ready to embed, or a placeholder of the right size for a
	/// variant that cannot be drawn.
	func decodedImage() -> DecodedImage {
		let placeholder = DecodedImage(width: width, height: height, pdfStream: nil)
		guard isSupported else { return placeholder }
		if !isInterlaced {
			switch colorType {
			case 0, 2:
				// Opaque, or transparent only where a sample matches the tRNS
				// colour key — which PDF can express directly as a /Mask.
				let stream = predictedStream(colorSpace: colorType == 0 ? "/DeviceGray" : "/DeviceRGB")
				if let colorKey { stream.setExtra("Mask", colorKey) }
				return DecodedImage(width: width, height: height, pdfStream: stream)
			case 3 where transparency == nil:
				return DecodedImage(width: width, height: height, pdfStream: predictedStream(colorSpace: indexedColorSpace))
			default:
				break
			}
		}
		// The header's dimensions are untrusted 32-bit values: their product can
		// overflow, and the decoder's own size arithmetic must never see one.
		let pixels = width.multipliedReportingOverflow(by: height)
		guard !pixels.overflow, pixels.partialValue <= Self.maximumDecodedPixels,
		      let image = try? unpackedImage() else { return placeholder }
		return image
	}

	// MARK: - Format

	/// Samples per pixel.
	private var channels: Int {
		switch colorType {
		case 2: return 3
		case 4: return 2
		case 6: return 4
		default: return 1 // grayscale, palette index
		}
	}

	/// The colour type and bit depth combinations the PNG specification allows.
	private var isSupported: Bool {
		switch (colorType, bitDepth) {
		case (0, 1), (0, 2), (0, 4), (0, 8), (0, 16): return true
		case (2, 8), (2, 16), (4, 8), (4, 16), (6, 8), (6, 16): return true
		case (3, 1), (3, 2), (3, 4), (3, 8): return palette.count >= 3
		default: return false
		}
	}

	/// The PNG scanlines as they are: FlateDecode with the PNG predictor.
	private func predictedStream(colorSpace: PDFValue) -> PDFStream {
		PDFStream(stream: [pixelData], extra: [
			("Type", "/XObject"),
			("Subtype", "/Image"),
			("Width", width),
			("Height", height),
			("ColorSpace", colorSpace),
			("BitsPerComponent", bitDepth),
			("Filter", "/FlateDecode"),
			("DecodeParms", PDFDictionary([
				("Predictor", 15),
				("Colors", colorType == 2 ? 3 : 1),
				("BitsPerComponent", bitDepth),
				("Columns", width)
			]))
		])
	}

	/// `[/Indexed /DeviceRGB hival <lookup>]` for the palette.
	private var indexedColorSpace: PDFArray {
		let entries = min(256, palette.count / 3)
		let lookup = palette.prefix(entries * 3).map { String(format: "%02x", $0) }.joined()
		return PDFArray(["/Indexed", "/DeviceRGB", entries - 1, Data("<\(lookup)>".utf8)])
	}

	/// The tRNS sample values of a grayscale or truecolor image as a PDF
	/// colour-key `/Mask` (one `[min max]` range per component).
	private var colorKey: PDFArray? {
		guard let transparency else { return nil }
		let components = colorType == 2 ? 3 : 1
		guard transparency.count >= components * 2 else { return nil }
		var ranges: [PDFValue] = []
		for component in 0 ..< components {
			let value = Int(transparency[2 * component]) << 8 | Int(transparency[2 * component + 1])
			ranges.append(value)
			ranges.append(value)
		}
		return PDFArray(ranges)
	}

	// MARK: - Decoding

	/// One pass over the image: every `dx`th pixel of every `dy`th row,
	/// starting at (`x`, `y`). A non-interlaced image is a single full pass.
	private struct Pass {
		let x, y, dx, dy: Int

		func size(width: Int, height: Int) -> (width: Int, height: Int) {
			((width - x + dx - 1) / dx, (height - y + dy - 1) / dy)
		}
	}

	private static let adam7 = [
		Pass(x: 0, y: 0, dx: 8, dy: 8), Pass(x: 4, y: 0, dx: 8, dy: 8),
		Pass(x: 0, y: 4, dx: 4, dy: 8), Pass(x: 2, y: 0, dx: 4, dy: 4),
		Pass(x: 0, y: 2, dx: 2, dy: 4), Pass(x: 1, y: 0, dx: 2, dy: 2),
		Pass(x: 0, y: 1, dx: 1, dy: 2)
	]

	/// Inflate and unfilter the scanlines, then split them into an 8-bit colour
	/// image and, when any pixel is not fully opaque, an alpha soft mask.
	private func unpackedImage() throws -> DecodedImage {
		let bitsPerPixel = channels * bitDepth
		let bytesPerPixel = max(1, bitsPerPixel / 8)
		let passes = isInterlaced ? Self.adam7 : [Pass(x: 0, y: 0, dx: 1, dy: 1)]
		var expectedSize = 0
		for pass in passes {
			let size = pass.size(width: width, height: height)
			if size.width > 0, size.height > 0 {
				expectedSize += size.height * (1 + (size.width * bitsPerPixel + 7) / 8)
			}
		}
		// Data past the last scanline is ignored, as browsers do, but the limit
		// still stops a stream that inflates far beyond the image.
		let scanlines = try Inflate.zlib(pixelData, limit: expectedSize + 4096)
		guard scanlines.count >= expectedSize else { throw Failure.truncated }

		// A palette image keeps its indices; everything else becomes gray or RGB.
		// A non-interlaced palette image embeds its original scanlines, so only
		// its mask is collected.
		let reusesScanlines = colorType == 3 && !isInterlaced
		let colorComponents = colorType == 2 || colorType == 6 ? 3 : 1
		var color = [UInt8](repeating: 0, count: reusesScanlines ? 0 : width * height * colorComponents)
		var alpha = [UInt8](repeating: 255, count: width * height)
		let key = colorKeySamples
		let maximumSample = (1 << bitDepth) - 1

		func sample(_ row: [UInt8], _ index: Int) -> Int {
			switch bitDepth {
			case 8: return Int(row[index])
			case 16: return Int(row[2 * index]) << 8 | Int(row[2 * index + 1])
			default:
				let bit = index * bitDepth
				return (Int(row[bit >> 3]) >> (8 - bitDepth - (bit & 7))) & maximumSample
			}
		}
		/// A raw sample scaled to 8 bits.
		func eightBit(_ value: Int) -> UInt8 {
			switch bitDepth {
			case 16: return UInt8(value >> 8)
			case 8: return UInt8(value)
			default: return UInt8(value * 255 / maximumSample)
			}
		}

		var offset = 0
		for pass in passes {
			let size = pass.size(width: width, height: height)
			guard size.width > 0, size.height > 0 else { continue }
			let rowBytes = (size.width * bitsPerPixel + 7) / 8
			var previous = [UInt8](repeating: 0, count: rowBytes)
			var row = [UInt8](repeating: 0, count: rowBytes)
			for passY in 0 ..< size.height {
				let filter = scanlines[offset]
				try Self.unfilter(filter, scanlines[offset + 1 ..< offset + 1 + rowBytes],
				                  previous: previous, bytesPerPixel: bytesPerPixel, into: &row)
				offset += 1 + rowBytes

				let y = pass.y + passY * pass.dy
				for passX in 0 ..< size.width {
					let pixel = y * width + pass.x + passX * pass.dx
					let first = passX * channels
					switch colorType {
					case 0:
						let gray = sample(row, first)
						color[pixel] = eightBit(gray)
						if let key, gray == key[0] { alpha[pixel] = 0 }
					case 2:
						let red = sample(row, first), green = sample(row, first + 1), blue = sample(row, first + 2)
						color[3 * pixel] = eightBit(red)
						color[3 * pixel + 1] = eightBit(green)
						color[3 * pixel + 2] = eightBit(blue)
						if let key, red == key[0], green == key[1], blue == key[2] { alpha[pixel] = 0 }
					case 3:
						let index = sample(row, first)
						if !reusesScanlines { color[pixel] = UInt8(index) }
						if let transparency, index < transparency.count { alpha[pixel] = transparency[index] }
					case 4:
						color[pixel] = eightBit(sample(row, first))
						alpha[pixel] = eightBit(sample(row, first + 1))
					default: // 6
						color[3 * pixel] = eightBit(sample(row, first))
						color[3 * pixel + 1] = eightBit(sample(row, first + 1))
						color[3 * pixel + 2] = eightBit(sample(row, first + 2))
						alpha[pixel] = eightBit(sample(row, first + 3))
					}
				}
				swap(&previous, &row)
			}
		}

		let colorStream: PDFStream
		if reusesScanlines {
			colorStream = predictedStream(colorSpace: indexedColorSpace)
		} else {
			let colorSpace: PDFValue
			switch colorType {
			case 3: colorSpace = indexedColorSpace
			case 2, 6: colorSpace = "/DeviceRGB"
			default: colorSpace = "/DeviceGray"
			}
			colorStream = Self.rawImageStream(color, width: width, height: height, colorSpace: colorSpace)
		}
		let softMask = alpha.contains { $0 != 255 }
			? Self.rawImageStream(alpha, width: width, height: height, colorSpace: "/DeviceGray")
			: nil
		return DecodedImage(width: width, height: height, pdfStream: colorStream, softMask: softMask)
	}

	/// The tRNS colour key of a grayscale or truecolor image, as raw samples.
	private var colorKeySamples: [Int]? {
		guard colorType == 0 || colorType == 2, let transparency else { return nil }
		let components = colorType == 2 ? 3 : 1
		guard transparency.count >= components * 2 else { return nil }
		return (0 ..< components).map { Int(transparency[2 * $0]) << 8 | Int(transparency[2 * $0 + 1]) }
	}

	/// An 8-bit image XObject over unfiltered samples, deflated when written.
	private static func rawImageStream(_ samples: [UInt8], width: Int, height: Int, colorSpace: PDFValue) -> PDFStream {
		let stream = PDFStream(stream: [Data(samples)], extra: [
			("Type", "/XObject"),
			("Subtype", "/Image"),
			("Width", width),
			("Height", height),
			("ColorSpace", colorSpace),
			("BitsPerComponent", 8)
		])
		stream.compressed = true
		return stream
	}

	/// Reverse one scanline's PNG filter (None, Sub, Up, Average or Paeth).
	private static func unfilter(_ filter: UInt8, _ line: ArraySlice<UInt8>, previous: [UInt8],
	                             bytesPerPixel: Int, into row: inout [UInt8]) throws {
		var source = line.startIndex
		for index in 0 ..< row.count {
			let raw = line[source]
			source += 1
			let left = index >= bytesPerPixel ? row[index - bytesPerPixel] : 0
			let above = previous[index]
			switch filter {
			case 0:
				row[index] = raw
			case 1:
				row[index] = raw &+ left
			case 2:
				row[index] = raw &+ above
			case 3:
				row[index] = raw &+ UInt8((Int(left) + Int(above)) / 2)
			case 4:
				let upperLeft = index >= bytesPerPixel ? previous[index - bytesPerPixel] : 0
				row[index] = raw &+ paeth(left, above, upperLeft)
			default:
				throw Failure.unknownFilter
			}
		}
	}

	private static func paeth(_ left: UInt8, _ above: UInt8, _ upperLeft: UInt8) -> UInt8 {
		let estimate = Int(left) + Int(above) - Int(upperLeft)
		let toLeft = abs(estimate - Int(left))
		let toAbove = abs(estimate - Int(above))
		let toUpperLeft = abs(estimate - Int(upperLeft))
		if toLeft <= toAbove && toLeft <= toUpperLeft { return left }
		return toAbove <= toUpperLeft ? above : upperLeft
	}
}
