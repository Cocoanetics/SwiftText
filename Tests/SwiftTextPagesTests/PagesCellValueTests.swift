import Foundation
import Testing

@testable import SwiftTextPages

/// Unit tests for decoding a cell's frozen numeric value — the IEEE 754-2008 decimal128
/// (BID) stored at byte 12 of a number cell. This is how a Pages table's computed
/// results (sums, etc.) read back as static Markdown text without a calculation engine.
@Suite("Cell value decoding")
struct PagesCellValueTests {
	/// Builds the 16 little-endian bytes of a BID decimal128 for `coefficient × 10^exponent`.
	private func decimal128Bytes(coefficient: UInt64, exponent: Int, negative: Bool = false) -> [UInt8] {
		let hi = (negative ? UInt64(1) << 63 : 0) | (UInt64(exponent + 6176) << 49)
		let lo = coefficient
		var bytes = [UInt8]()
		for k in 0..<8 { bytes.append(UInt8((lo >> (8 * k)) & 0xFF)) }
		for k in 0..<8 { bytes.append(UInt8((hi >> (8 * k)) & 0xFF)) }
		return bytes
	}

	@Test("decimal128 decodes integers, decimals, and signs")
	func decimal128() {
		func decode(_ c: UInt64, _ e: Int, neg: Bool = false) -> String? {
			PagesParser.decimal128String(decimal128Bytes(coefficient: c, exponent: e, negative: neg), at: 0)
		}
		#expect(decode(1, 0) == "1")
		#expect(decode(11, 0) == "11")
		#expect(decode(0, 0) == "0")
		#expect(decode(314, -2) == "3.14")        // 314 × 10^-2
		#expect(decode(250, -1) == "25")          // 25.0 → trailing zero trimmed
		#expect(decode(5, 0, neg: true) == "-5")
		#expect(decode(1500, 0) == "1500")
		#expect(decode(7, -3) == "0.007")
	}

	@Test("a real number cell's value is its decimal128 at byte 12")
	func numberCellLayout() {
		// 05 02 <header to 12> then the decimal128 for 42.
		var cell: [UInt8] = [0x05, 0x02, 0, 0, 0, 0, 0, 0, 0x01, 0x30, 0, 0]
		cell += decimal128Bytes(coefficient: 42, exponent: 0)
		#expect(PagesParser.decimal128String(cell, at: 12) == "42")
	}
}
