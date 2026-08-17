//  ZipContainerWriter.swift
//  SwiftTextZip
//
//  Writes the ZIP containers SwiftText produces — `.docx` (OPC) and `.epub`
//  (OCF) — with libarchive.
//
//  This drives the raw `archive_*` C API rather than swift-archive's
//  `ArchiveWriter`, for one reason: `ArchiveEntry.apply()` always calls
//  `archive_entry_set_uid/gid/mtime`, and libarchive emits a `ux` extra block
//  when uid/gid are set and a `UT` extra block when any timestamp is. Entries
//  here set none of the three, which no public API on `ArchiveWriter` can
//  currently express, and which buys two things:
//
//  * **A bare `mimetype` header.** EPUB's OCF container forbids *any* extra
//    field on that entry — the rule that puts `application/epub+zip` at the
//    fixed offset 38 reading systems sniff.
//  * **Reproducible output.** libarchive derives the MS-DOS timestamp with
//    `localtime()`, so a stamped archive would differ byte-for-byte between two
//    machines in different timezones, and the `UT` extra block would then carry
//    a machine-dependent value too. Unstamped entries date to the 1980 ZIP epoch
//    everywhere. Container formats keep their real dates in their own metadata
//    (`dcterms:modified` in an EPUB's OPF, `docProps` in an OPC package), which
//    is what readers surface anyway.
//
//  libarchive always writes streaming entries (general-purpose bit 3 set, sizes
//  and CRC in a trailing data descriptor) — `ZIP_ENTRY_FLAG_LENGTH_AT_END` is
//  unconditional, because it never knows the CRC when the local header goes out.
//  That is conformant for both formats: epubcheck accepts it, and so do OPC
//  readers. Formats that need the sizes *in* the local header — iWork's stored
//  `.pages` layout, which must reproduce Apple's bytes exactly — use
//  `StoredZipWriter` in SwiftTextPages instead.

import Foundation
import Archive

/// A regular file destined for a ZIP container.
public struct ZipContainerEntry: Sendable {
	/// Path inside the archive, e.g. `word/document.xml`.
	public let path: String
	public let data: Data
	/// When `false`, the entry is DEFLATEd (ZIP method 8).
	public let stored: Bool

	public init(path: String, data: Data, stored: Bool = false) {
		self.path = path
		self.data = data
		self.stored = stored
	}
}

public enum ZipContainerWriterError: Error, LocalizedError {
	case writeFailed(String)

	public var errorDescription: String? {
		switch self {
		case .writeFailed(let message): return "Could not write the ZIP container: \(message)"
		}
	}
}

public enum ZipContainerWriter {

	/// Writes `entries` to a ZIP archive at `url`, in the given order, replacing
	/// anything already there.
	public static func write(_ entries: [ZipContainerEntry], to url: URL) throws {
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		// Build beside the destination and move into place, so a failure part-way
		// through can't leave a half-written container behind.
		let staging = url.deletingLastPathComponent()
			.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
		defer { try? FileManager.default.removeItem(at: staging) }
		try writeArchive(entries, toPath: staging.path)
		try Data(contentsOf: staging).write(to: url, options: .atomic)
	}

	/// Builds the archive and returns its bytes, for callers that want the
	/// container in memory rather than on disk.
	public static func makeData(_ entries: [ZipContainerEntry]) throws -> Data {
		let staging = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-zip-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: staging) }
		try writeArchive(entries, toPath: staging.path)
		return try Data(contentsOf: staging)
	}

	private static func writeArchive(_ entries: [ZipContainerEntry], toPath path: String) throws {
		guard let archive = archive_write_new() else {
			throw ZipContainerWriterError.writeFailed("could not create a libarchive writer")
		}
		defer { archive_write_free(archive) }

		try check(archive_write_set_format_zip(archive), archive)
		try check(archive_write_open_filename(archive, path), archive)

		for entry in entries {
			try check(
				entry.stored
					? archive_write_zip_set_compression_store(archive)
					: archive_write_zip_set_compression_deflate(archive),
				archive
			)
			guard let header = archive_entry_new() else {
				throw ZipContainerWriterError.writeFailed("could not create a libarchive entry")
			}
			defer { archive_entry_free(header) }
			archive_entry_set_pathname(header, entry.path)
			archive_entry_set_filetype(header, Self.regularFile)
			archive_entry_set_size(header, Int64(entry.data.count))
			// uid/gid/mtime are deliberately never set — see the file comment.
			try check(archive_write_header(archive, header), archive)

			if !entry.data.isEmpty {
				let written = entry.data.withUnsafeBytes { buffer in
					archive_write_data(archive, buffer.baseAddress, buffer.count)
				}
				guard written == entry.data.count else {
					throw ZipContainerWriterError.writeFailed(errorMessage(archive))
				}
			}
		}

		try check(archive_write_close(archive), archive)
	}

	/// `AE_IFREG` — the macro uses a C cast Swift can't import.
	private static let regularFile: UInt32 = 0o100000

	private static func check(_ status: Int32, _ archive: OpaquePointer) throws {
		guard status != ARCHIVE_OK && status != ARCHIVE_WARN else { return }
		throw ZipContainerWriterError.writeFailed(errorMessage(archive))
	}

	private static func errorMessage(_ archive: OpaquePointer) -> String {
		archive_error_string(archive).map { String(cString: $0) } ?? "unknown libarchive error"
	}
}
