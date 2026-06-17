import Foundation
import SwiftTextCore
import Testing

struct ImageDimensionsTests {

	/// A real 1×1 RGB PNG (signature + IHDR + IDAT + IEND), 69 bytes.
	private static let tinyPNGBase64 =
		"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

	/// A 32×16 JPEG header: SOI, then an SOF0 frame (precision 8, height 0x0010,
	/// width 0x0020) followed by component padding. `fillBytes` extra 0xFF bytes are
	/// inserted before the SOF marker (legal JPEG fill bytes).
	private static func jpegHeader(fillBytes: Int) -> [UInt8] {
		var bytes: [UInt8] = [0xFF, 0xD8] // SOI
		bytes.append(contentsOf: Array(repeating: 0xFF, count: fillBytes))
		bytes.append(contentsOf: [
			0xFF, 0xC0,             // SOF0 marker
			0x00, 0x0B,             // segment length (11)
			0x08,                   // sample precision
			0x00, 0x10,             // height = 16
			0x00, 0x20,             // width = 32
			0x03, 0x01, 0x22, 0x00, // (truncated) component data
		])
		return bytes
	}

	@Test("PNG dimensions are read from the IHDR")
	func pngDimensions() throws {
		let png = try #require(Data(base64Encoded: Self.tinyPNGBase64))
		let dims = ImageDimensions.dimensions(of: [UInt8](png))
		#expect(dims?.width == 1)
		#expect(dims?.height == 1)
	}

	@Test("JPEG dimensions are read from the SOF (no fill bytes)")
	func jpegDimensionsBaseline() {
		let dims = ImageDimensions.dimensions(of: Self.jpegHeader(fillBytes: 0))
		#expect(dims?.width == 32)
		#expect(dims?.height == 16)
	}

	@Test("JPEG dimensions parse across leading 0xFF fill bytes")
	func jpegDimensionsWithFillBytes() {
		// Regression (Codex review, PR #28): 0xFF fill bytes before the SOF marker made
		// the scanner apply segment-length math to a fill byte and overshoot the frame,
		// returning nil — so a valid JPEG fell back to alt text instead of embedding.
		for fill in 1...4 {
			let dims = ImageDimensions.dimensions(of: Self.jpegHeader(fillBytes: fill))
			#expect(dims?.width == 32, "fill=\(fill)")
			#expect(dims?.height == 16, "fill=\(fill)")
		}
	}

	@Test("Non-image bytes return nil")
	func nonImageReturnsNil() {
		#expect(ImageDimensions.dimensions(of: [UInt8]("not an image".utf8)) == nil)
		#expect(ImageDimensions.dimensions(of: []) == nil)
	}
}
