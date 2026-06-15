import Foundation
import Testing

@testable import SwiftTextPages

@Suite("Snappy block decompression")
struct SnappyTests {
	@Test("Decompresses a literal-only block")
	func literalBlock() throws {
		// uncompressed length 5, one literal "Hello".
		let bytes: [UInt8] = [0x05, 0x10, 0x48, 0x65, 0x6C, 0x6C, 0x6F]
		let output = try Snappy.decompress(bytes)
		#expect(String(decoding: output, as: UTF8.self) == "Hello")
	}

	@Test("Resolves a back-reference copy with overlap")
	func overlappingCopy() throws {
		// length 12: literal "ABC" then a copy of 9 bytes from offset 3, which
		// must read bytes as it writes them — yields "ABCABCABCABC".
		let bytes: [UInt8] = [0x0C, 0x08, 0x41, 0x42, 0x43, 0x15, 0x03]
		let output = try Snappy.decompress(bytes)
		#expect(String(decoding: output, as: UTF8.self) == "ABCABCABCABC")
	}

	@Test("Round-trips arbitrary data through a literal block")
	func roundTrip() throws {
		let original = Array("The quick brown fox jumps over the lazy dog. ".utf8) + Array(0...255)
		let block = IWAWriter.snappyLiteralBlock(original)
		let output = try Snappy.decompress(block)
		#expect(output == original)
	}

	@Test("Rejects an out-of-range copy offset")
	func invalidOffset() {
		// uncompressed length 4, then a copy referencing further back than output.
		let bytes: [UInt8] = [0x04, 0x09, 0x10]
		#expect(throws: Snappy.Error.self) {
			_ = try Snappy.decompress(bytes)
		}
	}
}
