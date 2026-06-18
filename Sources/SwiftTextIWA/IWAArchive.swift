import Foundation

/// One archived object inside an `.iwa` file: a typed Protocol Buffers payload
/// addressed by a document-unique identifier.
public struct IWAObject {
	public let identifier: UInt64
	public let type: UInt64
	public let payload: [UInt8]

	public init(identifier: UInt64, type: UInt64, payload: [UInt8]) {
		self.identifier = identifier
		self.type = type
		self.payload = payload
	}
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
public enum IWAArchive {
	public enum Error: Swift.Error {
		case truncatedChunkHeader
		case truncatedChunkBody
		case objectNotFound
	}

	/// Decodes every object stored in a single `.iwa` file.
	public static func objects(from data: Data) throws -> [IWAObject] {
		let stream = try decompress(data)
		return parse(stream)
	}

	/// Maximum uncompressed bytes per Snappy block. iWork's writer slices the
	/// record stream into 64 KiB pieces and compresses each into its own chunk;
	/// we match that so Apple's reader is happy.
	private static let maxBlockSize = 1 << 16

	/// Frames a decompressed record stream into a complete `.iwa` file.
	///
	/// The stream is split into ≤ 64 KiB blocks; each is Snappy-compressed and
	/// prefixed with a 4-byte chunk header (a `0x00` flag byte and a 24-bit
	/// little-endian *compressed* length). There is deliberately no Snappy stream
	/// identifier and no CRC — Apple emits neither, and its reader expects neither.
	/// This is the exact inverse of ``decompress(_:)``, so re-emitting a stream the
	/// reader produced yields a file the reader (and Pages) reads back identically.
	public static func encode(stream: [UInt8]) -> Data {
		var output = [UInt8]()
		var pos = 0
		while pos < stream.count {
			let end = min(pos + maxBlockSize, stream.count)
			let block = Snappy.compress(Array(stream[pos..<end]))
			// The 24-bit length caps a block at ~16 MB; the 64 KiB slice keeps us
			// far below that, so the truncation to three bytes is always exact.
			output.append(0x00)
			output.append(UInt8(block.count & 0xFF))
			output.append(UInt8((block.count >> 8) & 0xFF))
			output.append(UInt8((block.count >> 16) & 0xFF))
			output.append(contentsOf: block)
			pos = end
		}
		return Data(output)
	}

	/// Serializes objects into a complete `.iwa` file.
	///
	/// Each object becomes one record — `varint(len(ArchiveInfo))`, then the
	/// `ArchiveInfo` (`identifier` = field 1, a single `MessageInfo` = field 2 with
	/// `type` = field 1 and `length` = field 3), then the payload — concatenated
	/// into the record stream that ``encode(stream:)`` frames. This mirrors
	/// ``parse(_:)`` and round-trips through ``objects(from:)``.
	public static func encode(_ objects: [IWAObject]) -> Data {
		var stream = [UInt8]()
		for object in objects {
			var messageInfo = ProtobufWriter()
			messageInfo.varintField(1, object.type)
			messageInfo.varintField(3, UInt64(object.payload.count))

			var archiveInfo = ProtobufWriter()
			archiveInfo.varintField(1, object.identifier)
			archiveInfo.messageField(2, messageInfo.bytes)

			stream.append(contentsOf: ProtobufWriter.varint(UInt64(archiveInfo.bytes.count)))
			stream.append(contentsOf: archiveInfo.bytes)
			stream.append(contentsOf: object.payload)
		}
		return encode(stream: stream)
	}

	/// Re-emits a `.iwa` file with one object's payload replaced.
	///
	/// Every *other* record is preserved byte-for-byte, and the edited object's
	/// `MessageInfo` keeps all its fields except `length` (field 3), which is set
	/// to the new payload size. This lets the writer inject content (e.g. body
	/// text) into a template object without disturbing the rest of the object
	/// graph, its cross-references, or any other component.
	/// - Parameters:
	///   - data: The original `.iwa` file.
	///   - objectID: The identifier of the object to edit (must store a single payload).
	///   - transform: Maps the object's current payload to its replacement.
	/// - Throws: ``Error/objectNotFound`` if no single-payload object has that id.
	public static func replacingPayload(in data: Data, objectID: UInt64, transform: ([UInt8]) -> [UInt8]) throws -> Data {
		let stream = try decompress(data)
		var output = [UInt8]()
		var pos = 0
		var replaced = false

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
			let recordStart = pos
			guard let archiveInfoLength = readVarint(), archiveInfoLength <= UInt64(stream.count - pos) else {
				throw Error.truncatedChunkBody
			}
			let archiveInfoEnd = pos + Int(archiveInfoLength)
			let archiveInfo = ProtobufMessage(Array(stream[pos..<archiveInfoEnd]))
			pos = archiveInfoEnd

			let identifier = archiveInfo.varint(1) ?? 0
			let messageInfos = archiveInfo.allBytes(2)
			// Advance past this record's payloads (one per MessageInfo, in order).
			var firstPayload: (start: Int, end: Int)?
			for messageInfoBytes in messageInfos {
				let length = ProtobufMessage(messageInfoBytes).varint(3) ?? 0
				guard length <= UInt64(stream.count - pos) else { throw Error.truncatedChunkBody }
				if firstPayload == nil { firstPayload = (pos, pos + Int(length)) }
				pos += Int(length)
			}

			if identifier == objectID, messageInfos.count == 1, !replaced, let payload = firstPayload {
				let newPayload = transform(Array(stream[payload.start..<payload.end]))
				// Rebuild MessageInfo: keep every field, update only length (#3).
				var messageInfoWriter = ProtobufWriter()
				for field in ProtobufMessage(messageInfos[0]).fields {
					if field.number == 3 {
						messageInfoWriter.varintField(3, UInt64(newPayload.count))
					} else {
						messageInfoWriter.append(field)
					}
				}
				// Rebuild ArchiveInfo: keep every field, swap in the new MessageInfo.
				var archiveInfoWriter = ProtobufWriter()
				for field in archiveInfo.fields {
					if field.number == 2 {
						archiveInfoWriter.bytesField(2, messageInfoWriter.bytes)
					} else {
						archiveInfoWriter.append(field)
					}
				}
				output.append(contentsOf: ProtobufWriter.varint(UInt64(archiveInfoWriter.bytes.count)))
				output.append(contentsOf: archiveInfoWriter.bytes)
				output.append(contentsOf: newPayload)
				replaced = true
			} else {
				// Copy the entire record (length prefix + ArchiveInfo + payloads) verbatim.
				output.append(contentsOf: stream[recordStart..<pos])
			}
		}

		guard replaced else { throw Error.objectNotFound }
		return encode(stream: output)
	}

	/// Re-emits a `.iwa` file with extra objects appended after the existing ones.
	///
	/// Existing records are preserved byte-for-byte; each new object is framed like
	/// ``encode(_:)`` (one `ArchiveInfo` with a single `MessageInfo`). Used to add
	/// freshly-built objects (e.g. character styles) into the document component
	/// that references them.
	public static func appending(_ objects: [IWAObject], to data: Data) throws -> Data {
		var stream = try decompress(data)
		for object in objects {
			var messageInfo = ProtobufWriter()
			messageInfo.varintField(1, object.type)
			messageInfo.varintField(3, UInt64(object.payload.count))

			var archiveInfo = ProtobufWriter()
			archiveInfo.varintField(1, object.identifier)
			archiveInfo.messageField(2, messageInfo.bytes)

			stream.append(contentsOf: ProtobufWriter.varint(UInt64(archiveInfo.bytes.count)))
			stream.append(contentsOf: archiveInfo.bytes)
			stream.append(contentsOf: object.payload)
		}
		return encode(stream: stream)
	}

	/// Re-emits a `.iwa` file with raw record-stream bytes appended.
	///
	/// `records` is already-framed record bytes (length-prefixed `ArchiveInfo` +
	/// payloads, as produced by capturing verbatim objects) concatenated together;
	/// they are appended to the decompressed stream and the whole thing re-framed.
	/// Used to inject a captured object set (e.g. a native table) into an existing
	/// component while preserving each object's full `ArchiveInfo` (object
	/// references included), which ``appending(_:to:)`` would not.
	public static func appendingRecordStream(_ records: [UInt8], to data: Data) throws -> Data {
		var stream = try decompress(data)
		stream.append(contentsOf: records)
		return encode(stream: stream)
	}

	/// De-chunks an `.iwa` file and concatenates the decompressed Snappy blocks.
	/// The inverse of ``encode(stream:)``.
	public static func decompress(_ data: Data) throws -> [UInt8] {
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
public struct IWAObjectStore {
	/// Objects in the order they were discovered (stream order within each file).
	public private(set) var objects = [IWAObject]()
	private var byIdentifier = [UInt64: Int]()

	public init() {}

	public mutating func add(_ object: IWAObject) {
		// First writer wins: the primary archive for an identifier appears before
		// any auxiliary ones, and is the one references expect to resolve to.
		if byIdentifier[object.identifier] == nil {
			byIdentifier[object.identifier] = objects.count
		}
		objects.append(object)
	}

	/// The primary object registered for an identifier, if any.
	public func object(_ identifier: UInt64) -> IWAObject? {
		guard let index = byIdentifier[identifier] else { return nil }
		return objects[index]
	}

	/// Every object of the given archive type, in discovery order.
	public func objects(ofType type: UInt64) -> [IWAObject] {
		objects.filter { $0.type == type }
	}
}
