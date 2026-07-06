//  EpubArchiveWriter.swift
//  SwiftTextEPUB
//
//  Packages the built EPUB files into the OCF ZIP container. The one hard rule
//  the format adds over an ordinary zip: the `mimetype` entry must come first
//  and be stored (uncompressed) with no extra field, so a reading system can
//  sniff the media type from a fixed offset before parsing anything. Everything
//  else is deflated, except already-compressed cover images, which are stored.

import Foundation
import ZIPFoundation

/// How a single packaged file is stored in the container.
enum EpubCompression {
	case stored
	case deflate
}

/// One file destined for the EPUB container, with its in-archive path.
struct EpubFile {
	let path: String
	let data: Data
	let compression: EpubCompression
}

enum EpubArchiveWriter {

	/// Writes `files` to a new EPUB archive at `url`, in the given order. The
	/// caller is responsible for placing `mimetype` first with `.stored`
	/// compression. `modificationDate` stamps every entry so the same input
	/// yields byte-identical output.
	static func write(_ files: [EpubFile], to url: URL, modificationDate: Date) throws {
		let directory = url.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		if FileManager.default.fileExists(atPath: url.path) {
			try FileManager.default.removeItem(at: url)
		}

		let archive = try Archive(url: url, accessMode: .create)
		for file in files {
			let method: CompressionMethod = file.compression == .stored ? .none : .deflate
			let data = file.data
			try archive.addEntry(
				with: file.path,
				type: .file,
				uncompressedSize: Int64(data.count),
				modificationDate: modificationDate,
				compressionMethod: method
			) { position, size in
				data.subdata(in: Data.Index(position) ..< Data.Index(position) + size)
			}
		}
	}

	/// Builds the archive in a temporary file and returns its bytes. Useful for
	/// callers (and tests) that want the EPUB as `Data` rather than on disk.
	static func makeData(_ files: [EpubFile], modificationDate: Date) throws -> Data {
		let temporary = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-epub-\(UUID().uuidString).epub")
		defer { try? FileManager.default.removeItem(at: temporary) }
		try write(files, to: temporary, modificationDate: modificationDate)
		return try Data(contentsOf: temporary)
	}
}
