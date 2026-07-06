//  Deflate.swift
//  SwiftTextPDFWriter
//
//  A small, dependency-free DEFLATE/zlib encoder used to compress PDF content
//  streams for `/Filter /FlateDecode`. It is deliberately pure Swift + Foundation
//  so it works on every platform SwiftText targets (macOS, iOS, Linux, Windows)
//  — unlike the Apple-only `Compression` framework, which isn't available on
//  swift-corelibs-foundation.
//
//  The output is a zlib stream (RFC 1950): a 2-byte header, a single DEFLATE
//  block using the fixed Huffman codes (RFC 1951 §3.2.6), and a big-endian
//  Adler-32 trailer. PDF's FlateDecode filter expects exactly this zlib wrapper.
//
//  Compression is LZ77 (a hash-chain match finder over a 32 KiB window) feeding
//  the fixed Huffman code tables. Fixed codes avoid the complexity of building
//  and transmitting dynamic Huffman trees while still capturing the bulk of the
//  win, which comes from LZ77 back-references — PDF content streams (repeated
//  glyph-drawing operators and coordinates) are highly repetitive and deflate
//  dramatically.

import Foundation

enum Deflate {
	/// Compress `input` into a zlib stream suitable for a PDF `/FlateDecode`
	/// filter. The result is always a valid RFC 1950 stream, even for empty or
	/// incompressible input (where it may be marginally larger than the source).
	static func zlib(_ input: Data) -> Data {
		var writer = BitWriter()
		writer.bytes.reserveCapacity(input.count / 2 + 16)
		// A single, final block using fixed Huffman codes: BFINAL=1, BTYPE=01.
		writer.writeBits(1, 1) // BFINAL
		writer.writeBits(1, 2) // BTYPE = 01 (fixed Huffman)
		compressBlock([UInt8](input), into: &writer)
		writer.align()

		var output = Data()
		output.reserveCapacity(writer.bytes.count + 6)
		output.append(0x78) // CMF: deflate method, 32 KiB window
		output.append(0x9C) // FLG: default level; FCHECK makes 0x789C divisible by 31
		output.append(contentsOf: writer.bytes)
		let checksum = adler32(input)
		output.append(UInt8((checksum >> 24) & 0xFF))
		output.append(UInt8((checksum >> 16) & 0xFF))
		output.append(UInt8((checksum >> 8) & 0xFF))
		output.append(UInt8(checksum & 0xFF))
		return output
	}

	// MARK: - LZ77 + fixed Huffman

	private static let minMatch = 3
	private static let maxMatch = 258
	private static let windowSize = 32768
	private static let hashSize = 1 << 15
	private static let hashMask = hashSize - 1
	private static let maxChain = 128
	private static let niceLength = 128 // stop searching once a match this long is found

	private static func hash(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Int {
		((Int(a) << 10) ^ (Int(b) << 5) ^ Int(c)) & hashMask
	}

	private static func compressBlock(_ data: [UInt8], into writer: inout BitWriter) {
		let n = data.count
		if n == 0 {
			writeSymbol(256, into: &writer) // end of block
			return
		}

		// Classic zlib chaining: `head[hash]` is the most recent position with a
		// given 3-byte hash; `prev[pos & wMask]` links to the previous one. Both
		// are bounded to the window, so memory is a fixed ~160 KiB regardless of
		// input size.
		let wMask = windowSize - 1
		var head = [Int32](repeating: -1, count: hashSize)
		var prev = [Int32](repeating: -1, count: windowSize)

		func insert(_ pos: Int) {
			let h = hash(data[pos], data[pos + 1], data[pos + 2])
			prev[pos & wMask] = head[h]
			head[h] = Int32(pos)
		}

		var pos = 0
		while pos < n {
			var bestLen = minMatch - 1
			var bestDist = 0

			if pos + minMatch <= n {
				let maxLen = min(maxMatch, n - pos)
				let h = hash(data[pos], data[pos + 1], data[pos + 2])
				var candidate = Int(head[h])
				var chain = maxChain
				while candidate >= 0 && chain > 0 {
					let dist = pos - candidate
					if dist > windowSize { break }
					chain -= 1
					// Only worth a full compare if it can beat the current best:
					// the byte at `bestLen` must already match.
					if data[candidate + bestLen] == data[pos + bestLen] {
						var len = 0
						while len < maxLen && data[candidate + len] == data[pos + len] {
							len += 1
						}
						if len > bestLen {
							bestLen = len
							bestDist = dist
							if len >= maxLen || len >= niceLength { break }
						}
					}
					candidate = Int(prev[candidate & wMask])
				}
			}

			if bestLen >= minMatch {
				emitMatch(length: bestLen, distance: bestDist, into: &writer)
				let end = pos + bestLen
				while pos < end {
					if pos + minMatch <= n { insert(pos) }
					pos += 1
				}
			} else {
				writeSymbol(Int(data[pos]), into: &writer) // literal
				if pos + minMatch <= n { insert(pos) }
				pos += 1
			}
		}
		writeSymbol(256, into: &writer) // end of block
	}

	// MARK: - Symbol emission

	/// The fixed Huffman code (MSB-first) and bit length for a literal/length
	/// symbol (0…287), per RFC 1951 §3.2.6.
	private static func litLenCode(_ sym: Int) -> (code: UInt32, bits: Int) {
		if sym <= 143 { return (UInt32(0x30 + sym), 8) }
		if sym <= 255 { return (UInt32(0x190 + sym - 144), 9) }
		if sym <= 279 { return (UInt32(sym - 256), 7) }
		return (UInt32(0xC0 + sym - 280), 8)
	}

	private static func writeSymbol(_ sym: Int, into writer: inout BitWriter) {
		let (code, bits) = litLenCode(sym)
		writer.writeHuffman(code, bits)
	}

	private static func emitMatch(length: Int, distance: Int, into writer: inout BitWriter) {
		let l = lengthLookup[length]
		writeSymbol(l.sym, into: &writer)
		if l.extra > 0 {
			writer.writeBits(UInt32(length - l.base), l.extra)
		}
		let d = distanceEntry(distance)
		// Fixed Huffman distance codes are the 5-bit symbol value itself.
		writer.writeHuffman(UInt32(d.sym), 5)
		if d.extra > 0 {
			writer.writeBits(UInt32(distance - d.base), d.extra)
		}
	}

	// MARK: - Length / distance code tables (RFC 1951 §3.2.5)

	private static let lengthTable: [(sym: Int, extra: Int, base: Int)] = [
		(257, 0, 3), (258, 0, 4), (259, 0, 5), (260, 0, 6), (261, 0, 7), (262, 0, 8), (263, 0, 9), (264, 0, 10),
		(265, 1, 11), (266, 1, 13), (267, 1, 15), (268, 1, 17),
		(269, 2, 19), (270, 2, 23), (271, 2, 27), (272, 2, 31),
		(273, 3, 35), (274, 3, 43), (275, 3, 51), (276, 3, 59),
		(277, 4, 67), (278, 4, 83), (279, 4, 99), (280, 4, 115),
		(281, 5, 131), (282, 5, 163), (283, 5, 195), (284, 5, 227),
		(285, 0, 258)
	]

	/// Maps every match length (3…258) to its length symbol and extra bits.
	/// Length 258 resolves to symbol 285 (its dedicated 0-extra-bit code), which
	/// is processed last and so overwrites symbol 284's overlapping range.
	private static let lengthLookup: [(sym: Int, extra: Int, base: Int)] = {
		var table = [(sym: Int, extra: Int, base: Int)](repeating: (0, 0, 0), count: maxMatch + 1)
		for entry in lengthTable {
			let upper = entry.sym == 285 ? 258 : entry.base + (1 << entry.extra) - 1
			var length = entry.base
			while length <= upper && length <= maxMatch {
				table[length] = entry
				length += 1
			}
		}
		return table
	}()

	private static let distanceTable: [(sym: Int, extra: Int, base: Int)] = [
		(0, 0, 1), (1, 0, 2), (2, 0, 3), (3, 0, 4),
		(4, 1, 5), (5, 1, 7),
		(6, 2, 9), (7, 2, 13),
		(8, 3, 17), (9, 3, 25),
		(10, 4, 33), (11, 4, 49),
		(12, 5, 65), (13, 5, 97),
		(14, 6, 129), (15, 6, 193),
		(16, 7, 257), (17, 7, 385),
		(18, 8, 513), (19, 8, 769),
		(20, 9, 1025), (21, 9, 1537),
		(22, 10, 2049), (23, 10, 3073),
		(24, 11, 4097), (25, 11, 6145),
		(26, 12, 8193), (27, 12, 12289),
		(28, 13, 16385), (29, 13, 24577)
	]

	private static func distanceEntry(_ distance: Int) -> (sym: Int, extra: Int, base: Int) {
		var result = distanceTable[0]
		for entry in distanceTable {
			if entry.base <= distance { result = entry } else { break }
		}
		return result
	}

	// MARK: - Adler-32 (RFC 1950)

	private static func adler32(_ data: Data) -> UInt32 {
		let mod: UInt32 = 65521
		var a: UInt32 = 1
		var b: UInt32 = 0
		data.withUnsafeBytes { raw in
			let bytes = raw.bindMemory(to: UInt8.self)
			var i = 0
			let count = bytes.count
			// Defer the modulo across chunks of 5552 bytes — the largest run that
			// cannot overflow a UInt32 accumulator — for speed on large streams.
			while i < count {
				let end = min(i + 5552, count)
				while i < end {
					a &+= UInt32(bytes[i])
					b &+= a
					i += 1
				}
				a %= mod
				b %= mod
			}
		}
		return (b << 16) | a
	}
}

/// Accumulates bits into a byte buffer using DEFLATE's packing rules: data
/// elements are written least-significant-bit first, while Huffman codes are
/// written most-significant-bit first (``writeHuffman(_:_:)`` reverses them).
private struct BitWriter {
	var bytes: [UInt8] = []
	private var bitBuffer: UInt32 = 0
	private var bitCount: Int = 0

	/// Append the low `count` bits of `value`, least-significant bit first.
	mutating func writeBits(_ value: UInt32, _ count: Int) {
		if count == 0 { return }
		let mask: UInt32 = count >= 32 ? .max : (UInt32(1) << UInt32(count)) - 1
		bitBuffer |= (value & mask) << UInt32(bitCount)
		bitCount += count
		while bitCount >= 8 {
			bytes.append(UInt8(bitBuffer & 0xFF))
			bitBuffer >>= 8
			bitCount -= 8
		}
	}

	/// Append a Huffman `code` of `bits` bits, most-significant bit first.
	mutating func writeHuffman(_ code: UInt32, _ bits: Int) {
		var reversed: UInt32 = 0
		var remaining = code
		for _ in 0 ..< bits {
			reversed = (reversed << 1) | (remaining & 1)
			remaining >>= 1
		}
		writeBits(reversed, bits)
	}

	/// Flush any partial byte, padding with zero bits.
	mutating func align() {
		if bitCount > 0 {
			bytes.append(UInt8(bitBuffer & 0xFF))
			bitBuffer = 0
			bitCount = 0
		}
	}
}
