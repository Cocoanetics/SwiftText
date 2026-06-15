import Foundation

/// Minimal decompressor for the Snappy block format used inside iWork `.iwa`
/// chunks.
///
/// iWork does *not* use the framed Snappy stream format. Each IWA chunk carries
/// a single raw Snappy block: a varint-encoded uncompressed length followed by a
/// sequence of literal/copy elements. Only decompression is implemented — the
/// format is read-only here.
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
}
