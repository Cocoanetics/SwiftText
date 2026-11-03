//  Inflate.swift
//  SwiftTextRender
//
//  A small, dependency-free zlib/DEFLATE decoder (RFC 1950/1951) — the
//  counterpart of SwiftTextPDFWriter's encoder, in pure Swift so it runs on
//  every platform SwiftText targets. PNG keeps its pixels deflated; the image
//  decoder only inflates them when a PDF cannot take the PNG data as it is,
//  such as an alpha channel that has to become a separate soft mask.
//
//  Huffman codes are decoded canonically, a bit at a time, from per-length
//  symbol counts — the approach of zlib's reference decoder `puff.c`. That is
//  compact and easy to verify, and fast enough for the logos and icons that
//  documents and emails carry.

import Foundation

enum Inflate {
	enum Failure: Error, Equatable {
		case invalidHeader
		case truncated
		case invalidBlockType
		case invalidStoredBlock
		case invalidCodeLengths
		case invalidCode
		case invalidDistance
		case outputLimitExceeded
	}

	/// Decompress a zlib stream: a 2-byte header, DEFLATE data and an Adler-32
	/// trailer (which is not verified; PNG checksums its chunks itself).
	///
	/// - Parameter limit: The most bytes the output may grow to; exceeding it
	///   throws, which stops a corrupt or hostile stream from exhausting memory.
	static func zlib(_ data: Data, limit: Int = .max) throws -> [UInt8] {
		let bytes = [UInt8](data)
		guard bytes.count >= 2 else { throw Failure.invalidHeader }
		let method = bytes[0] & 0x0F
		let checksum = (Int(bytes[0]) << 8 | Int(bytes[1])) % 31
		let presetDictionary = bytes[1] & 0x20 != 0
		guard method == 8, checksum == 0, !presetDictionary else { throw Failure.invalidHeader }
		var inflater = Inflater(input: bytes, position: 2, limit: limit)
		try inflater.inflate()
		return inflater.output
	}

	/// Decompress raw DEFLATE data (no zlib wrapper).
	static func deflated(_ data: Data, limit: Int = .max) throws -> [UInt8] {
		var inflater = Inflater(input: [UInt8](data), position: 0, limit: limit)
		try inflater.inflate()
		return inflater.output
	}
}

/// A canonical Huffman code: how many codes each bit length has, and the
/// symbols in code order.
private struct HuffmanCode {
	static let maximumBits = 15

	var counts = [Int](repeating: 0, count: maximumBits + 1)
	var symbols: [Int]
	/// Whether the lengths claim more codes than a prefix code can hold — a
	/// corrupt stream. An incomplete code is fine; DEFLATE allows those for
	/// sparse alphabets.
	private(set) var isOversubscribed = false

	/// Build the code for per-symbol bit lengths (0 = symbol unused).
	init(lengths: ArraySlice<Int>) {
		symbols = [Int](repeating: 0, count: lengths.count)
		for length in lengths { counts[length] += 1 }
		var left = 1
		for length in 1 ... Self.maximumBits {
			left = (left << 1) - counts[length]
			if left < 0 { isOversubscribed = true }
		}
		var offsets = [Int](repeating: 0, count: Self.maximumBits + 1)
		for length in 1 ..< Self.maximumBits {
			offsets[length + 1] = offsets[length] + counts[length]
		}
		for (symbol, length) in lengths.enumerated() where length != 0 {
			symbols[offsets[length]] = symbol
			offsets[length] += 1
		}
	}
}

private struct Inflater {
	let input: [UInt8]
	var position: Int
	let limit: Int
	var output: [UInt8] = []
	private var bitBuffer: UInt32 = 0
	private var bitCount = 0

	init(input: [UInt8], position: Int, limit: Int) {
		self.input = input
		self.position = position
		self.limit = limit
	}

	mutating func inflate() throws {
		var isLast = false
		while !isLast {
			isLast = try bits(1) == 1
			switch try bits(2) {
			case 0: try storedBlock()
			case 1: try codes(literals: Self.fixedLiterals, distances: Self.fixedDistances)
			case 2: try dynamicBlock()
			default: throw Inflate.Failure.invalidBlockType
			}
		}
	}

	// MARK: - Bits

	/// Read `count` bits, least significant first, as DEFLATE packs them.
	private mutating func bits(_ count: Int) throws -> Int {
		var buffer = bitBuffer
		while bitCount < count {
			guard position < input.count else { throw Inflate.Failure.truncated }
			buffer |= UInt32(input[position]) << UInt32(bitCount)
			position += 1
			bitCount += 8
		}
		bitBuffer = buffer >> UInt32(count)
		bitCount -= count
		return Int(buffer & ((1 << UInt32(count)) - 1))
	}

	private mutating func decode(_ code: HuffmanCode) throws -> Int {
		var value = 0, first = 0, index = 0
		for length in 1 ... HuffmanCode.maximumBits {
			value |= try bits(1)
			let count = code.counts[length]
			if value - count < first { return code.symbols[index + value - first] }
			index += count
			first = (first + count) << 1
			value <<= 1
		}
		throw Inflate.Failure.invalidCode
	}

	private mutating func append(_ byte: UInt8) throws {
		guard output.count < limit else { throw Inflate.Failure.outputLimitExceeded }
		output.append(byte)
	}

	// MARK: - Blocks

	private mutating func storedBlock() throws {
		// A stored block starts on a byte boundary; `bits` never buffers more
		// than the rest of the current byte, so dropping it realigns.
		bitBuffer = 0
		bitCount = 0
		guard position + 4 <= input.count else { throw Inflate.Failure.truncated }
		let length = Int(input[position]) | Int(input[position + 1]) << 8
		let complement = Int(input[position + 2]) | Int(input[position + 3]) << 8
		guard length == ~complement & 0xFFFF else { throw Inflate.Failure.invalidStoredBlock }
		position += 4
		guard position + length <= input.count else { throw Inflate.Failure.truncated }
		guard output.count + length <= limit else { throw Inflate.Failure.outputLimitExceeded }
		output.append(contentsOf: input[position ..< position + length])
		position += length
	}

	private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

	private mutating func dynamicBlock() throws {
		let literalCount = try bits(5) + 257
		let distanceCount = try bits(5) + 1
		let codeLengthCount = try bits(4) + 4
		guard literalCount <= 286, distanceCount <= 30 else { throw Inflate.Failure.invalidCodeLengths }

		var codeLengthLengths = [Int](repeating: 0, count: 19)
		for index in 0 ..< codeLengthCount {
			codeLengthLengths[Self.codeLengthOrder[index]] = try bits(3)
		}
		let codeLengthCode = HuffmanCode(lengths: codeLengthLengths[...])
		guard !codeLengthCode.isOversubscribed else { throw Inflate.Failure.invalidCodeLengths }

		var lengths: [Int] = []
		lengths.reserveCapacity(literalCount + distanceCount)
		while lengths.count < literalCount + distanceCount {
			let symbol = try decode(codeLengthCode)
			let repeated: Int
			let length: Int
			switch symbol {
			case 0 ... 15:
				lengths.append(symbol)
				continue
			case 16:
				guard let previous = lengths.last else { throw Inflate.Failure.invalidCodeLengths }
				length = previous
				repeated = 3 + (try bits(2))
			case 17:
				length = 0
				repeated = 3 + (try bits(3))
			default:
				length = 0
				repeated = 11 + (try bits(7))
			}
			guard lengths.count + repeated <= literalCount + distanceCount else { throw Inflate.Failure.invalidCodeLengths }
			lengths.append(contentsOf: repeatElement(length, count: repeated))
		}
		// Without an end-of-block code the block could never finish.
		guard lengths[256] != 0 else { throw Inflate.Failure.invalidCodeLengths }

		let literals = HuffmanCode(lengths: lengths[..<literalCount])
		let distances = HuffmanCode(lengths: lengths[literalCount...])
		guard !literals.isOversubscribed, !distances.isOversubscribed else { throw Inflate.Failure.invalidCodeLengths }
		try codes(literals: literals, distances: distances)
	}

	private static let lengthBases = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
	                                  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
	private static let lengthExtraBits = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
	                                      3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
	private static let distanceBases = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
	                                    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
	                                    8193, 12289, 16385, 24577]
	private static let distanceExtraBits = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
	                                        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

	// The fixed codes of RFC 1951 §3.2.6.
	private static let fixedLiterals = HuffmanCode(lengths: (0 ..< 288).map { symbol -> Int in
		switch symbol {
		case 0 ..< 144: return 8
		case 144 ..< 256: return 9
		case 256 ..< 280: return 7
		default: return 8
		}
	}[...])
	private static let fixedDistances = HuffmanCode(lengths: [Int](repeating: 5, count: 30)[...])

	/// Decode literal/length and distance codes until the end-of-block code.
	private mutating func codes(literals: HuffmanCode, distances: HuffmanCode) throws {
		while true {
			let symbol = try decode(literals)
			if symbol < 256 {
				try append(UInt8(symbol))
				continue
			}
			if symbol == 256 { return }

			let lengthIndex = symbol - 257
			guard lengthIndex < Self.lengthBases.count else { throw Inflate.Failure.invalidCode }
			let length = Self.lengthBases[lengthIndex] + (try bits(Self.lengthExtraBits[lengthIndex]))
			let distanceIndex = try decode(distances)
			guard distanceIndex < Self.distanceBases.count else { throw Inflate.Failure.invalidDistance }
			let distance = Self.distanceBases[distanceIndex] + (try bits(Self.distanceExtraBits[distanceIndex]))
			guard distance <= output.count else { throw Inflate.Failure.invalidDistance }
			guard output.count + length <= limit else { throw Inflate.Failure.outputLimitExceeded }
			// Byte by byte: a match may overlap the bytes it is still producing.
			var source = output.count - distance
			for _ in 0 ..< length {
				output.append(output[source])
				source += 1
			}
		}
	}
}
