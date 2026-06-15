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

	@Test("Compression round-trips through the decompressor")
	func compressRoundTrip() throws {
		// Deterministic pseudo-random (≈ incompressible) bytes.
		var state: UInt64 = 0x2545_F491_4F6C_DD1D
		var pseudoRandom = [UInt8]()
		for _ in 0..<8000 {
			state = state &* 6364136223846793005 &+ 1442695040888963407
			pseudoRandom.append(UInt8((state >> 32) & 0xFF))
		}

		let cases: [[UInt8]] = [
			[],
			[0x2A],
			Array("hello".utf8),
			Array("the quick brown fox jumps over the lazy dog".utf8),
			Array(repeating: 0x41, count: 5000),                  // long run (RLE-style)
			(0..<4000).map { UInt8(0x61 + ($0 % 6)) },            // periodic "abcdef…"
			pseudoRandom,                                         // incompressible
			pseudoRandom + Array(repeating: 0x7E, count: 70000),  // spans more than one window
		]
		for input in cases {
			#expect(try Snappy.decompress(Snappy.compress(input)) == input)
		}
	}

	@Test("Actually compresses repetitive data")
	func compressionShrinksRepetitiveData() {
		let input = Array(repeating: UInt8(0x41), count: 5000)
		#expect(Snappy.compress(input).count < input.count)
	}
}
