import Foundation

/// One archived object inside an `.iwa` file: a typed Protocol Buffers payload
/// addressed by a document-unique identifier.
struct IWAObject {
	let identifier: UInt64
	let type: UInt64
	let payload: [UInt8]
}

/// Decodes the iWork Archive (`.iwa`) container format into its objects.
///
/// An `.iwa` file is a sequence of chunks. Each chunk is a 4-byte header
/// (`0x00` flag byte followed by a 24-bit little-endian length) and a single
/// raw Snappy block. Concatenating the decompressed blocks yields a stream of
/// records, each made of:
///
///   - a varint length, then that many bytes of `TSP.ArchiveInfo`
///     (`identifier` = field 1, repeated `MessageInfo` = field 2);
///   - for every `MessageInfo` (`type` = field 1, `length` = field 3), that
///     many bytes of the object's payload message.
enum IWAArchive {
	enum Error: Swift.Error {
		case truncatedChunkHeader
		case truncatedChunkBody
	}

	/// Decodes every object stored in a single `.iwa` file.
	static func objects(from data: Data) throws -> [IWAObject] {
		let stream = try decompress(data)
		return parse(stream)
	}

	/// De-chunks an `.iwa` file and concatenates the decompressed Snappy blocks.
	private static func decompress(_ data: Data) throws -> [UInt8] {
		let bytes = [UInt8](data)
		var pos = 0
		var stream = [UInt8]()
		while pos < bytes.count {
			guard pos + 4 <= bytes.count else { throw Error.truncatedChunkHeader }
			// bytes[pos] is a flag (always 0x00 in practice); length is the next 3.
			let length = Int(bytes[pos + 1]) | Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3]) << 16
			pos += 4
			guard pos + length <= bytes.count else { throw Error.truncatedChunkBody }
			let block = Array(bytes[pos..<pos + length])
			pos += length
			stream.append(contentsOf: try Snappy.decompress(block))
		}
		return stream
	}

	/// Walks the decompressed record stream into `IWAObject`s.
	private static func parse(_ stream: [UInt8]) -> [IWAObject] {
		var objects = [IWAObject]()
		var pos = 0

		func readVarint() -> UInt64? {
			var shift = UInt64(0)
			var result = UInt64(0)
			while pos < stream.count {
				let byte = stream[pos]
				pos += 1
				result |= UInt64(byte & 0x7F) << shift
				if byte & 0x80 == 0 { return result }
				shift += 7
				if shift >= 64 { return nil }
			}
			return nil
		}

		while pos < stream.count {
			// Bound-check lengths against the remaining bytes before converting to
			// Int, so a corrupt oversized varint degrades gracefully instead of
			// trapping (this stream comes from untrusted archives).
			guard let archiveInfoLength = readVarint(), archiveInfoLength <= UInt64(stream.count - pos) else { break }
			let end = pos + Int(archiveInfoLength)
			let archiveInfo = ProtobufMessage(Array(stream[pos..<end]))
			pos = end

			let identifier = archiveInfo.varint(1) ?? 0
			// Each MessageInfo describes one payload message that follows, in order.
			for messageInfo in archiveInfo.messages(2) {
				let type = messageInfo.varint(1) ?? 0
				let length = messageInfo.varint(3) ?? 0
				guard length <= UInt64(stream.count - pos) else { return objects }
				let payloadEnd = pos + Int(length)
				objects.append(IWAObject(identifier: identifier, type: type, payload: Array(stream[pos..<payloadEnd])))
				pos = payloadEnd
			}
		}

		return objects
	}
}

/// An in-memory index of every object across a document's `.iwa` files,
/// addressable by identifier. Mirrors how iWork resolves cross-file references.
struct IWAObjectStore {
	/// Objects in the order they were discovered (stream order within each file).
	private(set) var objects = [IWAObject]()
	private var byIdentifier = [UInt64: Int]()

	mutating func add(_ object: IWAObject) {
		// First writer wins: the primary archive for an identifier appears before
		// any auxiliary ones, and is the one references expect to resolve to.
		if byIdentifier[object.identifier] == nil {
			byIdentifier[object.identifier] = objects.count
		}
		objects.append(object)
	}

	/// The primary object registered for an identifier, if any.
	func object(_ identifier: UInt64) -> IWAObject? {
		guard let index = byIdentifier[identifier] else { return nil }
		return objects[index]
	}

	/// Every object of the given archive type, in discovery order.
	func objects(ofType type: UInt64) -> [IWAObject] {
		objects.filter { $0.type == type }
	}
}
