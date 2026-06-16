import Foundation

/// Minimal ZIP writer that **stores** every entry uncompressed (no DEFLATE, no
/// Zip64, no data descriptors) — the layout iWork uses and Pages expects for a
/// `.pages` package. Entries are written in the order they are added.
///
/// Hand-rolled rather than via ZIPFoundation so the output byte-for-byte matches
/// the stored-zip form already verified to open in Pages, and so the writer keeps
/// no extra dependency for this small, well-specified task.
struct StoredZipWriter {
	/// Per-entry ZIP metadata that doesn't affect content but *does* affect the exact
	/// bytes — preserved from a source archive so a round-trip is byte-identical, or
	/// left at Apple-like defaults when synthesizing. Apple's `.pages` writer stamps a
	/// real DOS timestamp on every entry, marks the central directory "version made by"
	/// 6.2, and reserves a 16-byte Zip64 extra field in the *local* header of every
	/// non-`Index/` entry (`Metadata/…`, previews) while leaving the central copy bare.
	struct Metadata {
		var dosTime: UInt16 = 0
		var dosDate: UInt16 = 0x21          // 1980-01-01 (a valid default)
		var versionMadeBy: UInt16 = 20
		var versionNeeded: UInt16 = 20
		var flags: UInt16 = 0
		var internalAttributes: UInt16 = 0
		var externalAttributes: UInt32 = 0
		var localExtra: [UInt8] = []
		var centralExtra: [UInt8] = []
	}

	private struct Entry {
		let path: [UInt8]
		let crc: UInt32
		let size: Int
		let offset: Int
		let meta: Metadata
	}

	private var localSection = [UInt8]()
	private var entries = [Entry]()

	/// Appends one stored entry, optionally with preserved ZIP metadata.
	mutating func add(path: String, data: [UInt8], meta: Metadata = Metadata()) {
		let offset = localSection.count
		let crc = CRC32.checksum(data)
		let name = Array(path.utf8)

		var header = [UInt8]()
		Self.appendUInt32(&header, 0x0403_4b50)            // local file header signature
		Self.appendUInt16(&header, meta.versionNeeded)     // version needed to extract
		Self.appendUInt16(&header, meta.flags)             // general purpose flags
		Self.appendUInt16(&header, 0)                      // method: 0 = stored
		Self.appendUInt16(&header, meta.dosTime)           // last mod time
		Self.appendUInt16(&header, meta.dosDate)           // last mod date
		Self.appendUInt32(&header, crc)
		Self.appendUInt32(&header, UInt32(data.count))     // compressed size
		Self.appendUInt32(&header, UInt32(data.count))     // uncompressed size
		Self.appendUInt16(&header, UInt16(name.count))     // file name length
		Self.appendUInt16(&header, UInt16(meta.localExtra.count))
		header += name
		header += meta.localExtra

		localSection += header
		localSection += data
		entries.append(Entry(path: name, crc: crc, size: data.count, offset: offset, meta: meta))
	}

	/// Produces the complete ZIP archive bytes.
	func finish() -> Data {
		var output = localSection
		let centralStart = output.count

		for entry in entries {
			var header = [UInt8]()
			Self.appendUInt32(&header, 0x0201_4b50)             // central directory header signature
			Self.appendUInt16(&header, entry.meta.versionMadeBy)
			Self.appendUInt16(&header, entry.meta.versionNeeded)
			Self.appendUInt16(&header, entry.meta.flags)
			Self.appendUInt16(&header, 0)                       // method: stored
			Self.appendUInt16(&header, entry.meta.dosTime)
			Self.appendUInt16(&header, entry.meta.dosDate)
			Self.appendUInt32(&header, entry.crc)
			Self.appendUInt32(&header, UInt32(entry.size))      // compressed size
			Self.appendUInt32(&header, UInt32(entry.size))      // uncompressed size
			Self.appendUInt16(&header, UInt16(entry.path.count))
			Self.appendUInt16(&header, UInt16(entry.meta.centralExtra.count))
			Self.appendUInt16(&header, 0)                       // comment length
			Self.appendUInt16(&header, 0)                       // disk number start
			Self.appendUInt16(&header, entry.meta.internalAttributes)
			Self.appendUInt32(&header, entry.meta.externalAttributes)
			Self.appendUInt32(&header, UInt32(entry.offset))
			header += entry.path
			header += entry.meta.centralExtra
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

/// Reads a flat (STORED) ZIP — `.pages`/`.numbers`/`.key` single-file packages — into
/// entries that keep every byte-affecting field, so ``StoredZipWriter`` can reproduce
/// the archive exactly. Walks the central directory (authoritative for order and
/// metadata) and pairs each entry with its local-header extra field.
enum ZipReader {
	struct Entry {
		let path: String
		let data: [UInt8]
		let meta: StoredZipWriter.Metadata
	}

	/// Parses `data` as a STORED zip, or returns nil if it isn't one (e.g. a directory
	/// package or a compressed archive — callers fall back to their generic reader).
	static func read(_ data: [UInt8]) -> [Entry]? {
		guard let eocd = findEOCD(data) else { return nil }
		let count = u16(data, eocd + 10)
		var pos = Int(u32(data, eocd + 16))               // central directory offset
		var entries = [Entry]()
		for _ in 0..<count {
			guard pos + 46 <= data.count, u32(data, pos) == 0x0201_4b50 else { return nil }
			let versionMadeBy = u16(data, pos + 4)
			let versionNeeded = u16(data, pos + 6)
			let flags = u16(data, pos + 8)
			let method = u16(data, pos + 10)
			guard method == 0 else { return nil }          // stored only
			let dosTime = u16(data, pos + 12), dosDate = u16(data, pos + 14)
			let size = Int(u32(data, pos + 20))
			let nameLen = Int(u16(data, pos + 28))
			let centralExtraLen = Int(u16(data, pos + 30))
			let commentLen = Int(u16(data, pos + 32))
			let internalAttr = u16(data, pos + 36)
			let externalAttr = u32(data, pos + 38)
			let localOffset = Int(u32(data, pos + 42))
			let name = String(decoding: data[pos + 46 ..< pos + 46 + nameLen], as: UTF8.self)
			let centralExtra = Array(data[pos + 46 + nameLen ..< pos + 46 + nameLen + centralExtraLen])

			// Local header: read the extra field (Apple stores a Zip64 placeholder here)
			// and the payload, which follows name + local-extra.
			guard localOffset + 30 <= data.count, u32(data, localOffset) == 0x0403_4b50 else { return nil }
			let localNameLen = Int(u16(data, localOffset + 26))
			let localExtraLen = Int(u16(data, localOffset + 28))
			let localExtra = Array(data[localOffset + 30 + localNameLen ..< localOffset + 30 + localNameLen + localExtraLen])
			let dataStart = localOffset + 30 + localNameLen + localExtraLen
			guard dataStart + size <= data.count else { return nil }

			let meta = StoredZipWriter.Metadata(
				dosTime: dosTime, dosDate: dosDate, versionMadeBy: versionMadeBy,
				versionNeeded: versionNeeded, flags: flags, internalAttributes: internalAttr,
				externalAttributes: externalAttr, localExtra: localExtra, centralExtra: centralExtra)
			entries.append(Entry(path: name, data: Array(data[dataStart ..< dataStart + size]), meta: meta))
			pos += 46 + nameLen + centralExtraLen + commentLen
		}
		return entries
	}

	private static func findEOCD(_ data: [UInt8]) -> Int? {
		guard data.count >= 22 else { return nil }
		var i = data.count - 22
		let lowest = max(0, data.count - 22 - 65535)
		while i >= lowest {
			if u32(data, i) == 0x0605_4b50 { return i }
			i -= 1
		}
		return nil
	}

	private static func u16(_ d: [UInt8], _ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
	private static func u32(_ d: [UInt8], _ o: Int) -> UInt32 {
		UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
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
