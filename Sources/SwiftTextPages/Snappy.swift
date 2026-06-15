import Foundation

/// Codec for the Snappy block format used inside iWork `.iwa` chunks.
///
/// iWork does *not* use the framed Snappy stream format. Each IWA chunk carries
/// a single raw Snappy block: a varint-encoded uncompressed length followed by a
/// sequence of literal/copy elements.
///
/// `decompress` reads that format; `compress` produces it (the foundation for
/// writing `.iwa` files). The compressor is an original LZ77 implementation per
/// the format spec — its output is valid Snappy but not byte-identical to
/// Google's reference (match choices differ), which is fine: any compliant
/// decompressor reads it back.
enum Snappy {
	enum Error: Swift.Error {
		case truncated
		case invalidOffset
	}

	/// Decompresses a single raw Snappy block.
	/// - Parameter input: The compressed block bytes (no stream framing).
	/// - Returns: The decompressed bytes.
	static func decompress(_ input: [UInt8]) throws -> [UInt8] {
		var pos = 0

		func readVarint() throws -> Int {
			var shift = 0
			var result = 0
			while true {
				guard pos < input.count else { throw Error.truncated }
				let byte = input[pos]
				pos += 1
				result |= Int(byte & 0x7F) << shift
				if byte & 0x80 == 0 { break }
				shift += 7
			}
			return result
		}

		func readLittleEndian(_ count: Int) throws -> Int {
			guard pos + count <= input.count else { throw Error.truncated }
			var value = 0
			for index in 0..<count {
				value |= Int(input[pos + index]) << (8 * index)
			}
			pos += count
			return value
		}

		let expectedLength = try readVarint()
		var output = [UInt8]()
		output.reserveCapacity(expectedLength)

		while pos < input.count {
			let tag = input[pos]
			pos += 1
			let elementType = tag & 0x03

			if elementType == 0 {
				// Literal: the upper 6 bits hold (length - 1), or signal that the
				// length spills into 1–4 following little-endian bytes.
				var length = Int(tag >> 2)
				if length >= 60 {
					let extraBytes = length - 59
					length = try readLittleEndian(extraBytes)
				}
				length += 1
				guard pos + length <= input.count else { throw Error.truncated }
				output.append(contentsOf: input[pos..<pos + length])
				pos += length
			} else {
				// Copy: emit `length` bytes from earlier in the output, `offset`
				// back from the current end.
				let length: Int
				let offset: Int
				switch elementType {
				case 1:
					length = Int((tag >> 2) & 0x07) + 4
					guard pos < input.count else { throw Error.truncated }
					offset = (Int(tag >> 5) << 8) | Int(input[pos])
					pos += 1
				case 2:
					length = Int(tag >> 2) + 1
					offset = try readLittleEndian(2)
				default: // 3
					length = Int(tag >> 2) + 1
					offset = try readLittleEndian(4)
				}

				guard offset > 0, offset <= output.count else { throw Error.invalidOffset }
				// Offsets may overlap the region being written (run-length style),
				// so the copy must proceed one byte at a time.
				var sourceIndex = output.count - offset
				for _ in 0..<length {
					output.append(output[sourceIndex])
					sourceIndex += 1
				}
			}
		}

		return output
	}

	/// Compresses bytes into a single raw Snappy block (varint length + element
	/// stream), the form an IWA chunk wraps.
	static func compress(_ input: [UInt8]) -> [UInt8] {
		var output = [UInt8]()
		appendVarint(UInt64(input.count), to: &output)
		// Match within 64 KiB windows so back-reference offsets stay ≤ 65535
		// (1- or 2-byte copy forms); the reference compressor does the same.
		let windowSize = 1 << 16
		var windowStart = 0
		while windowStart < input.count {
			let windowEnd = min(windowStart + windowSize, input.count)
			compressWindow(input, from: windowStart, to: windowEnd, into: &output)
			windowStart = windowEnd
		}
		return output
	}

	/// Emits literals and back-reference copies for one window, finding matches
	/// with a hash table over 4-byte sequences.
	private static func compressWindow(_ input: [UInt8], from start: Int, to end: Int, into output: inout [UInt8]) {
		var nextEmit = start
		if end - start >= 4 {
			let logTableSize = 14
			var table = [Int](repeating: -1, count: 1 << logTableSize)
			let shift = UInt32(32 - logTableSize)
			let matchLimit = end - 4 // last index from which 4 bytes can be read
			var index = start
			while index <= matchLimit {
				let word = load32(input, index)
				let hash = Int((word &* 0x1e35a7bd) >> shift)
				let candidate = table[hash]
				table[hash] = index
				if candidate >= start, candidate < index, index - candidate <= 65535, load32(input, candidate) == word {
					emitLiteral(input, from: nextEmit, to: index, into: &output)
					var matched = 4
					while index + matched < end, input[candidate + matched] == input[index + matched] {
						matched += 1
					}
					emitCopy(offset: index - candidate, length: matched, into: &output)
					index += matched
					nextEmit = index
				} else {
					index += 1
				}
			}
		}
		emitLiteral(input, from: nextEmit, to: end, into: &output)
	}

	private static func load32(_ input: [UInt8], _ index: Int) -> UInt32 {
		UInt32(input[index]) | (UInt32(input[index + 1]) << 8)
			| (UInt32(input[index + 2]) << 16) | (UInt32(input[index + 3]) << 24)
	}

	private static func appendVarint(_ value: UInt64, to output: inout [UInt8]) {
		var remaining = value
		repeat {
			var byte = UInt8(remaining & 0x7F)
			remaining >>= 7
			if remaining > 0 { byte |= 0x80 }
			output.append(byte)
		} while remaining > 0
	}

	private static func emitLiteral(_ input: [UInt8], from: Int, to: Int, into output: inout [UInt8]) {
		let length = to - from
		guard length > 0 else { return }
		let lengthMinusOne = length - 1
		if lengthMinusOne < 60 {
			output.append(UInt8(lengthMinusOne << 2))
		} else {
			var lengthBytes = [UInt8]()
			var value = lengthMinusOne
			while value > 0 {
				lengthBytes.append(UInt8(value & 0xFF))
				value >>= 8
			}
			output.append(UInt8((59 + lengthBytes.count) << 2))
			output.append(contentsOf: lengthBytes)
		}
		output.append(contentsOf: input[from..<to])
	}

	private static func emitCopy(offset: Int, length: Int, into output: inout [UInt8]) {
		var remaining = length
		while remaining > 0 {
			if remaining >= 4, remaining <= 11, offset <= 2047 {
				// 1-byte-offset copy (tag type 01).
				let tag = ((offset >> 8) << 5) | ((remaining - 4) << 2) | 0x01
				output.append(UInt8(tag))
				output.append(UInt8(offset & 0xFF))
				remaining = 0
			} else {
				// 2-byte-offset copy (tag type 10), max 64 bytes per element.
				let take = min(remaining, 64)
				output.append(UInt8(((take - 1) << 2) | 0x02))
				output.append(UInt8(offset & 0xFF))
				output.append(UInt8((offset >> 8) & 0xFF))
				remaining -= take
			}
		}
	}
}
