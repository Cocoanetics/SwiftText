import Foundation

/// One archived object that preserves its **full record framing**, so a payload can be
/// re-encoded (e.g. through a generated typed model) without losing the cross-object
/// links Pages needs. The `MessageInfo` is kept verbatim — type (`#1`), version (`#2`),
/// the `FieldInfo` (`#4`), `object_references` (`#5`), `data_references` (`#6`) — and
/// only the payload length (`#3`) is recomputed on write. Because a typed re-encode
/// keeps every referenced id in the payload, the original `#5` stays correct.
struct IWARecord {
	/// One `MessageInfo` (`#2`) and the payload that follows it. An `ArchiveInfo` carries
	/// a *repeated* `MessageInfo`, each with its own payload, in order — so a record can
	/// hold several message parts (most have exactly one).
	struct Part {
		var messageInfo: [ProtobufField]
		var payload: [UInt8]
		var type: UInt64 {
			for field in messageInfo where field.number == 1 { if case .varint(let v) = field.value { return v } }
			return 0
		}
	}
	var identifier: UInt64
	var parts: [Part]

	/// The primary object type (first message part).
	var type: UInt64 { parts.first?.type ?? 0 }

	/// The record bytes: `varint(len(ArchiveInfo))` + `ArchiveInfo` (id `#1` + every
	/// `MessageInfo` `#2`, each with `#3` set to its payload length) + every payload in
	/// order. Every other `MessageInfo` field (version `#2`, `FieldInfo` `#4`,
	/// object_references `#5`, data_references `#6`) is preserved verbatim.
	var framed: [UInt8] {
		var archive = ProtobufWriter()
		archive.varintField(1, identifier)
		for part in parts {
			var info = ProtobufWriter()
			var wroteLength = false
			for field in part.messageInfo {
				if field.number == 3 { info.varintField(3, UInt64(part.payload.count)); wroteLength = true }
				else { info.append(field) }
			}
			if !wroteLength { info.varintField(3, UInt64(part.payload.count)) }
			archive.bytesField(2, info.bytes)
		}
		var out = ProtobufWriter.varint(UInt64(archive.bytes.count))
		out.append(contentsOf: archive.bytes)
		for part in parts { out.append(contentsOf: part.payload) }
		return out
	}
}

/// A complete iWork package as an ordered list of files — each `Index/*.iwa` parsed into
/// framing-preserving `IWARecord`s, everything else (Metadata/, preview, …) kept raw.
/// Read a document in, optionally rebuild object payloads through the typed models, and
/// write a valid package back out — the foundation for programmatic ("cold") synthesis.
struct IWAPackage {
	enum Content { case iwa([IWARecord]); case raw([UInt8]) }
	var files: [(path: String, content: Content)]

	/// Parses `entries` (path + raw bytes) into a package. `Index/*.iwa` files are parsed
	/// into records; any file that isn't standard Snappy/Protobuf IWA is kept raw.
	static func read(_ entries: [(path: String, bytes: [UInt8])]) -> IWAPackage {
		var files = [(path: String, content: Content)]()
		for entry in entries {
			if entry.path.hasPrefix("Index/"), entry.path.hasSuffix(".iwa"),
			   let records = try? parseRecords(Data(entry.bytes)) {
				files.append((entry.path, .iwa(records)))
			} else {
				files.append((entry.path, .raw(entry.bytes)))
			}
		}
		return IWAPackage(files: files)
	}

	/// Re-encodes every modeled object's payload through its generated typed model
	/// (decode → encode), proving the whole document survives a round-trip through the
	/// object layer. Unmodeled objects are left byte-for-byte unchanged.
	mutating func reencodeThroughModels() {
		for i in files.indices {
			guard case .iwa(var records) = files[i].content else { continue }
			for r in records.indices {
				for p in records[r].parts.indices where IWATypeRegistry.modeledTypes.contains(records[r].parts[p].type) {
					if let re = IWATypeRegistry.reencode(type: records[r].parts[p].type, payload: records[r].parts[p].payload) {
						records[r].parts[p].payload = re
					}
				}
			}
			files[i].content = .iwa(records)
		}
	}

	/// Serializes the package to a `.pages` (STORED zip) at `url`.
	func write(to url: URL) throws {
		var zip = StoredZipWriter()
		for file in files {
			switch file.content {
			case .iwa(let records):
				var stream = [UInt8]()
				for record in records { stream.append(contentsOf: record.framed) }
				zip.add(path: file.path, data: [UInt8](IWAArchive.encode(stream: stream)))
			case .raw(let bytes):
				zip.add(path: file.path, data: bytes)
			}
		}
		try zip.finish().write(to: url)
	}

	/// Splits a decompressed `.iwa` record stream into framing-preserving records.
	private static func parseRecords(_ data: Data) throws -> [IWARecord] {
		let stream = try IWAArchive.decompress(data)
		var records = [IWARecord]()
		var pos = 0
		func readVarint() -> UInt64? {
			var shift = UInt64(0), result = UInt64(0)
			while pos < stream.count {
				let b = stream[pos]; pos += 1
				result |= UInt64(b & 0x7F) << shift
				if b & 0x80 == 0 { return result }
				shift += 7; if shift >= 64 { return nil }
			}
			return nil
		}
		while pos < stream.count {
			guard let aiLen = readVarint(), pos + Int(aiLen) <= stream.count else { break }
			let archive = ProtobufMessage(Array(stream[pos..<pos + Int(aiLen)])); pos += Int(aiLen)
			guard let identifier = archive.varint(1) else { break }
			// Each MessageInfo (#2) describes one payload that follows, in order.
			var parts = [IWARecord.Part]()
			for info in archive.messages(2) {
				let payloadLen = Int(info.varint(3) ?? 0)
				guard pos + payloadLen <= stream.count else { return records }
				parts.append(.init(messageInfo: info.fields, payload: Array(stream[pos..<pos + payloadLen])))
				pos += payloadLen
			}
			records.append(IWARecord(identifier: identifier, parts: parts))
		}
		return records
	}
}
