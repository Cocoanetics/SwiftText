import SwiftTextIWA
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
		/// When set, the part is *synthesized*: `framed` emits a fresh `MessageInfo`
		/// (`#1` type, `#3` length, `#5` these object references as packed varints)
		/// rather than preserving `messageInfo`. nil means "preserve Apple's framing".
		var synthesizedReferences: [UInt64]?
		var type: UInt64 {
			for field in messageInfo where field.number == 1 { if case .varint(let v) = field.value { return v } }
			return 0
		}

		/// A synthesized part: minimal `MessageInfo` (`#1` type) plus computed references.
		static func synthesized(type: UInt64, payload: [UInt8], references: [UInt64]) -> Part {
			Part(messageInfo: [ProtobufField(number: 1, value: .varint(type))],
			     payload: payload, synthesizedReferences: references)
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
			if let references = part.synthesizedReferences {
				// Synthesized framing: type (#1), length (#3), object_references (#5).
				info.varintField(1, part.type)
				info.varintField(3, UInt64(part.payload.count))
				if !references.isEmpty { info.packedVarintField(5, references) }
			} else {
				var wroteLength = false
				for field in part.messageInfo {
					if field.number == 3 { info.varintField(3, UInt64(part.payload.count)); wroteLength = true } else { info.append(field) }
				}
				if !wroteLength { info.varintField(3, UInt64(part.payload.count)) }
			}
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
	/// An `.iwa` component carries its parsed records *and* the original compressed
	/// bytes it was read from. On write, a component whose records are all unchanged is
	/// re-emitted verbatim from `original` — a writer never recompresses what it didn't
	/// touch, which also gives an exact byte-parity round-trip (Apple's Snappy output is
	/// not uniquely determined, so re-compressing identical content needn't match it).
	enum Content { case iwa([IWARecord], original: [UInt8]?); case raw([UInt8]) }
	var files: [(path: String, content: Content)]
	/// Per-entry ZIP metadata (timestamps, extra fields, version) captured when read
	/// from a flat package, so writing reproduces the container byte-for-byte. Empty
	/// for packages read from loose entries (the writer then uses Apple-like defaults).
	var zipMeta: [String: StoredZipWriter.Metadata] = [:]

	/// Reads a flat (STORED-zip) `.pages` straight from its bytes, capturing both the
	/// object graph and the ZIP container metadata for a byte-faithful round-trip.
	/// Returns nil if `data` isn't a flat zip (e.g. a directory package).
	static func read(zip data: [UInt8]) -> IWAPackage? {
		guard let entries = ZipReader.read(data) else { return nil }
		var package = read(entries.map { ($0.path, $0.data) })
		for entry in entries { package.zipMeta[entry.path] = entry.meta }
		return package
	}

	/// Parses `entries` (path + raw bytes) into a package. `Index/*.iwa` files are parsed
	/// into records (keeping the original bytes for verbatim re-emit); any file that isn't
	/// standard Snappy/Protobuf IWA is kept raw.
	static func read(_ entries: [(path: String, bytes: [UInt8])]) -> IWAPackage {
		var files = [(path: String, content: Content)]()
		for entry in entries {
			if entry.path.hasPrefix("Index/"), entry.path.hasSuffix(".iwa"),
			   let records = try? parseRecords(Data(entry.bytes)) {
				files.append((entry.path, .iwa(records, original: entry.bytes)))
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
			guard case .iwa(var records, _) = files[i].content else { continue }
			for r in records.indices {
				for p in records[r].parts.indices where IWATypeRegistry.modeledTypes.contains(records[r].parts[p].type) {
					if let re = IWATypeRegistry.reencode(type: records[r].parts[p].type, payload: records[r].parts[p].payload) {
						records[r].parts[p].payload = re
					}
				}
			}
			// The payloads changed, so drop the verbatim original — re-encode on write.
			files[i].content = .iwa(records, original: nil)
		}
	}

	/// The on-disk bytes for one file: an unchanged `.iwa` component is re-emitted from
	/// its original compressed bytes verbatim (exact round-trip); a modified one is
	/// re-framed and re-compressed; raw files pass through.
	private func serialized(_ content: Content) -> [UInt8] {
		switch content {
		case .iwa(let records, let original):
			let dirty = records.contains { $0.parts.contains { $0.synthesizedReferences != nil } }
			if let original, !dirty { return original }
			var stream = [UInt8]()
			for record in records { stream.append(contentsOf: record.framed) }
			return [UInt8](IWAArchive.encode(stream: stream))
		case .raw(let bytes):
			return bytes
		}
	}

	/// Serializes the package to a flat (single-file STORED zip) `.pages` at `url`.
	func write(to url: URL) throws {
		var zip = StoredZipWriter()
		for file in files {
			zip.add(path: file.path, data: serialized(file.content), meta: zipMeta[file.path] ?? StoredZipWriter.Metadata())
		}
		try zip.finish().write(to: url)
	}

	/// Reads a *directory-style* `.pages` package: a folder whose `Index/*.iwa` files
	/// live in a nested STORED `Index.zip`, with `Metadata/…` and previews as loose
	/// files on disk. Captures the nested zip's per-entry metadata for a byte-faithful
	/// round-trip. Returns nil if `url` isn't a directory package with a readable index.
	static func read(directoryPackageAt url: URL) -> IWAPackage? {
		let fm = FileManager.default
		var isDir: ObjCBool = false
		guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
		let indexZip = url.appendingPathComponent("Index.zip")
		guard let zipBytes = try? [UInt8](Data(contentsOf: indexZip)), let entries = ZipReader.read(zipBytes) else { return nil }

		var package = IWAPackage(files: [])
		for entry in entries {
			if entry.path.hasSuffix(".iwa"), let records = try? parseRecords(Data(entry.data)) {
				package.files.append((entry.path, .iwa(records, original: entry.data)))
			} else {
				package.files.append((entry.path, .raw(entry.data)))
			}
			package.zipMeta[entry.path] = entry.meta
		}
		// Loose files: everything in the bundle except Index.zip, by relative path.
		// Resolve symlinks on both sides — the enumerator yields canonical `/private/var`
		// paths while `url` may be `/var`, so a naive prefix strip would mangle the path.
		let rootPath = url.resolvingSymlinksInPath().path
		if let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
			for case let fileURL as URL in walker {
				guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
				let path = fileURL.resolvingSymlinksInPath().path
				guard path.hasPrefix(rootPath + "/") else { continue }
				let rel = String(path.dropFirst(rootPath.count + 1))
				if rel == "Index.zip" { continue }
				if let bytes = try? [UInt8](Data(contentsOf: fileURL)) { package.files.append((rel, .raw(bytes))) }
			}
		}
		return package
	}

	/// Writes a *directory-style* `.pages` package at `url`: the `Index/*.iwa` files are
	/// re-zipped into `Index.zip` (preserving the nested zip's metadata), and every other
	/// file is written loose, recreating the bundle byte-for-byte for an unchanged read.
	func writeDirectoryPackage(to url: URL) throws {
		let fm = FileManager.default
		try fm.createDirectory(at: url, withIntermediateDirectories: true)
		var zip = StoredZipWriter()
		for file in files where file.path.hasPrefix("Index/") {
			zip.add(path: file.path, data: serialized(file.content), meta: zipMeta[file.path] ?? StoredZipWriter.Metadata())
		}
		try zip.finish().write(to: url.appendingPathComponent("Index.zip"))
		for file in files where !file.path.hasPrefix("Index/") {
			let dest = url.appendingPathComponent(file.path)
			try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
			try Data(serialized(file.content)).write(to: dest)
		}
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
