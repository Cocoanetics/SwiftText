import Foundation

/// Minimal ZIP writer that **stores** every entry uncompressed (no DEFLATE, no
/// Zip64, no data descriptors) — the layout iWork uses and Pages expects for a
/// `.pages` package. Entries are written in the order they are added.
///
/// Hand-rolled rather than via ZIPFoundation so the output byte-for-byte matches
/// the stored-zip form already verified to open in Pages, and so the writer keeps
/// no extra dependency for this small, well-specified task.
struct StoredZipWriter {
	private struct Entry {
		let path: [UInt8]
		let crc: UInt32
		let size: Int
		let offset: Int
	}

	private var localSection = [UInt8]()
	private var entries = [Entry]()

	/// Appends one stored entry.
	mutating func add(path: String, data: [UInt8]) {
		let offset = localSection.count
		let crc = CRC32.checksum(data)
		let name = Array(path.utf8)

		var header = [UInt8]()
		Self.appendUInt32(&header, 0x0403_4b50)        // local file header signature
		Self.appendUInt16(&header, 20)                 // version needed to extract
		Self.appendUInt16(&header, 0)                  // general purpose flags
		Self.appendUInt16(&header, 0)                  // method: 0 = stored
		Self.appendUInt16(&header, 0)                  // last mod time
		Self.appendUInt16(&header, 0x21)               // last mod date (1980-01-01, valid)
		Self.appendUInt32(&header, crc)
		Self.appendUInt32(&header, UInt32(data.count)) // compressed size
		Self.appendUInt32(&header, UInt32(data.count)) // uncompressed size
		Self.appendUInt16(&header, UInt16(name.count)) // file name length
		Self.appendUInt16(&header, 0)                  // extra field length
		header += name

		localSection += header
		localSection += data
		entries.append(Entry(path: name, crc: crc, size: data.count, offset: offset))
	}

	/// Produces the complete ZIP archive bytes.
	func finish() -> Data {
		var output = localSection
		let centralStart = output.count

		for entry in entries {
			var header = [UInt8]()
			Self.appendUInt32(&header, 0x0201_4b50)         // central directory header signature
			Self.appendUInt16(&header, 20)                  // version made by
			Self.appendUInt16(&header, 20)                  // version needed to extract
			Self.appendUInt16(&header, 0)                   // flags
			Self.appendUInt16(&header, 0)                   // method: stored
			Self.appendUInt16(&header, 0)                   // time
			Self.appendUInt16(&header, 0x21)                // date
			Self.appendUInt32(&header, entry.crc)
			Self.appendUInt32(&header, UInt32(entry.size))  // compressed size
			Self.appendUInt32(&header, UInt32(entry.size))  // uncompressed size
			Self.appendUInt16(&header, UInt16(entry.path.count))
			Self.appendUInt16(&header, 0)                   // extra length
			Self.appendUInt16(&header, 0)                   // comment length
			Self.appendUInt16(&header, 0)                   // disk number start
			Self.appendUInt16(&header, 0)                   // internal attributes
			Self.appendUInt32(&header, 0)                   // external attributes
			Self.appendUInt32(&header, UInt32(entry.offset))
			header += entry.path
			output += header
		}

		let centralSize = output.count - centralStart
		var eocd = [UInt8]()
		Self.appendUInt32(&eocd, 0x0605_4b50)               // end of central directory signature
		Self.appendUInt16(&eocd, 0)                         // this disk number
		Self.appendUInt16(&eocd, 0)                         // disk with central directory
		Self.appendUInt16(&eocd, UInt16(entries.count))     // entries on this disk
		Self.appendUInt16(&eocd, UInt16(entries.count))     // total entries
		Self.appendUInt32(&eocd, UInt32(centralSize))
		Self.appendUInt32(&eocd, UInt32(centralStart))
		Self.appendUInt16(&eocd, 0)                         // comment length
		output += eocd

		return Data(output)
	}

	private static func appendUInt16(_ bytes: inout [UInt8], _ value: UInt16) {
		bytes.append(UInt8(value & 0xFF))
		bytes.append(UInt8((value >> 8) & 0xFF))
	}

	private static func appendUInt32(_ bytes: inout [UInt8], _ value: UInt32) {
		bytes.append(UInt8(value & 0xFF))
		bytes.append(UInt8((value >> 8) & 0xFF))
		bytes.append(UInt8((value >> 16) & 0xFF))
		bytes.append(UInt8((value >> 24) & 0xFF))
	}
}

/// CRC-32 (IEEE 802.3 polynomial), as ZIP requires for each entry.
enum CRC32 {
	private static let table: [UInt32] = (0..<256).map { index in
		var crc = UInt32(index)
		for _ in 0..<8 {
			crc = (crc & 1) != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
		}
		return crc
	}

	static func checksum(_ bytes: [UInt8]) -> UInt32 {
		var crc: UInt32 = 0xFFFF_FFFF
		for byte in bytes {
			crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
		}
		return crc ^ 0xFFFF_FFFF
	}
}
