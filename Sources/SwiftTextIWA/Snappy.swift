import Foundation

/// Codec for the Snappy block format used inside iWork `.iwa` chunks.
///
/// iWork does *not* use the framed Snappy stream format. Each IWA chunk carries
/// a single raw Snappy block: a varint-encoded uncompressed length followed by a
/// sequence of literal/copy elements.
///
/// `decompress` reads that format; `compress` produces it. The compressor is a faithful
/// port of Snappy's `CompressFragment` using the **multiply-shift hash** — `((bytes *
/// 0x1e35a7bd) >> (32 - 14)) & mask` — so its output is byte-identical to what Apple's
/// iWork ships, not merely a valid alternative encoding. This hash is shared by Snappy
/// **1.1.9 and 1.1.10's scalar path** (1.1.10 refactored it but the net table index is
/// identical: `(>>17) & 2·(ts−1)` over a uint16 stride == `(>>18) & (ts−1)`). Established
/// empirically: compiling the reference Snappy at every release tag, only 1.1.9/1.1.10
/// reproduce real `.pages` blocks, and this port is byte-identical to the 1.1.9 binary.
/// Note: 1.1.10 *also* added an optional hardware **CRC32 hash**; Apple does **not** use
/// it (a CRC32-built 1.1.10 mismatches every real block), so the multiply-shift hash here
/// is the correct — not merely older — choice. Other decisive details: `CalculateTableSize`
/// downsizing, the `skip += bytes_between` search heuristic, the 64/60/remainder chunking.
public enum Snappy {
	public enum Error: Swift.Error {
		case truncated
		case invalidOffset
	}

	/// Decompresses a single raw Snappy block.
	/// - Parameter input: The compressed block bytes (no stream framing).
	/// - Returns: The decompressed bytes.
	public static func decompress(_ input: [UInt8]) throws -> [UInt8] {
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
	///
	/// This is a faithful port of Google Snappy's `Compress`/`CompressFragment` —
	/// the same encoder iWork uses — so its output is **byte-identical** to Apple's,
	/// not merely a valid alternative encoding. Matching it exactly (variable
	/// per-fragment hash-table size, the `skip` search heuristic, the post-match hash
	/// insertions, and the 64/60/remainder copy chunking) is what lets a `.pages`
	/// round-trip with full byte parity.
	public static func compress(_ input: [UInt8]) -> [UInt8] {
		var output = [UInt8]()
		appendVarint(UInt64(input.count), to: &output)
		// Snappy compresses in fragments of at most 64 KiB; each is an independent
		// scan with its own hash table (iWork already chunks at 64 KiB, so usually
		// one fragment per call, but the general loop matches `Compress` exactly).
		let kBlockSize = 1 << 16
		var start = 0
		while start < input.count {
			let end = min(start + kBlockSize, input.count)
			compressFragment(input, start, end, into: &output)
			start = end
		}
		return output
	}

	/// Hash-table size for a fragment, matching Snappy's `CalculateTableSize`: the
	/// smallest power of two ≥ the fragment length, floored at 256 and capped at 2¹⁴
	/// (16384). iWork uses this standard downsizing (confirmed by compiling the vendored
	/// reference Snappy and matching its per-block output against real `.pages` files).
	private static func hashTableSize(_ fragmentSize: Int) -> Int {
		var size = 256
		while size < (1 << 14) && size < fragmentSize { size <<= 1 }
		return size
	}

	private static func load32(_ input: [UInt8], _ index: Int) -> UInt32 {
		UInt32(input[index]) | (UInt32(input[index + 1]) << 8)
			| (UInt32(input[index + 2]) << 16) | (UInt32(input[index + 3]) << 24)
	}

	/// Snappy's `HashBytes`: `((bytes * 0x1e35a7bd) >> (32 - kMaxHashTableBits)) & mask`.
	/// The shift is *fixed* at 18 (kMaxHashTableBits = 14) regardless of table size; only
	/// the `& mask` narrows it to the table. Using a table-relative shift instead — which
	/// looks equivalent for the full 16384 table but isn't for smaller ones — was the bug
	/// that made small blocks (1024-entry tables) diverge from Apple.
	private static func hash(_ input: [UInt8], _ index: Int, _ mask: UInt32) -> Int {
		Int(((load32(input, index) &* 0x1e35a7bd) >> 18) & mask)
	}

	/// Bytes that match starting at `s1`/`s2`, bounded by the fragment `end`.
	private static func findMatchLength(_ input: [UInt8], _ s1: Int, _ s2: Int, _ end: Int) -> Int {
		var matched = 0
		while s2 + matched < end, input[s1 + matched] == input[s2 + matched] { matched += 1 }
		return matched
	}

	/// A faithful port of Snappy's `CompressFragment` for one ≤ 64 KiB fragment.
	private static func compressFragment(_ input: [UInt8], _ start: Int, _ end: Int, into output: inout [UInt8]) {
		let fragmentSize = end - start
		let tableSize = hashTableSize(fragmentSize)
		let mask = UInt32(tableSize - 1)                          // hash is masked to the table
		var table = [Int](repeating: 0, count: tableSize)         // positions relative to `start`; 0 ⇒ start
		var nextEmit = start
		let kInputMargin = 15

		if fragmentSize >= kInputMargin {
			let ipLimit = end - kInputMargin
			var ip = start + 1
			var nextHash = hash(input, ip, mask)

			outer: while true {
				var skip = 32
				var nextIP = ip
				var candidate = 0
				// Search forward (skipping ahead on misses) for a 4-byte match.
				while true {
					ip = nextIP
					let h = nextHash
					let bytesBetween = skip >> 5
					skip += bytesBetween
					nextIP = ip + bytesBetween
					if nextIP > ipLimit { break outer }
					nextHash = hash(input, nextIP, mask)
					candidate = start + table[h]
					table[h] = ip - start
					if load32(input, ip) == load32(input, candidate) { break }
				}

				// Emit the literal run [nextEmit, ip), then one or more copies.
				emitLiteral(input, from: nextEmit, to: ip, into: &output)

				while true {
					let base = ip
					let matched = 4 + findMatchLength(input, candidate + 4, ip + 4, end)
					ip += matched
					emitCopy(offset: base - candidate, length: matched, into: &output)
					nextEmit = ip
					if ip >= ipLimit { break outer }
					// Insert hashes for ip-1 and ip; continue copying if ip matches.
					let prevHash = hash(input, ip - 1, mask)
					table[prevHash] = (ip - 1) - start
					let curHash = hash(input, ip, mask)
					candidate = start + table[curHash]
					table[curHash] = ip - start
					if load32(input, ip) != load32(input, candidate) {
						nextHash = hash(input, ip + 1, mask)
						ip += 1
						break
					}
				}
			}
		}
		// Emit any trailing bytes as a final literal.
		if nextEmit < end { emitLiteral(input, from: nextEmit, to: end, into: &output) }
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

	/// Snappy's `EmitCopy`: long copies are split 64…(60)…remainder so the decoder
	/// always keeps ≥ 4 bytes in hand; each piece is a 1- or 2-byte-offset element.
	private static func emitCopy(offset: Int, length: Int, into output: inout [UInt8]) {
		var len = length
		while len >= 68 { emitCopyAtMost64(offset: offset, length: 64, into: &output); len -= 64 }
		if len > 64 { emitCopyAtMost64(offset: offset, length: 60, into: &output); len -= 60 }
		emitCopyAtMost64(offset: offset, length: len, into: &output)
	}

	private static func emitCopyAtMost64(offset: Int, length: Int, into output: inout [UInt8]) {
		if length < 12, offset < 2048 {
			// 1-byte-offset copy (tag type 01).
			output.append(UInt8(0x01 | ((length - 4) << 2) | ((offset >> 8) << 5)))
			output.append(UInt8(offset & 0xFF))
		} else {
			// 2-byte-offset copy (tag type 10).
			output.append(UInt8(0x02 | ((length - 1) << 2)))
			output.append(UInt8(offset & 0xFF))
			output.append(UInt8((offset >> 8) & 0xFF))
		}
	}
}
