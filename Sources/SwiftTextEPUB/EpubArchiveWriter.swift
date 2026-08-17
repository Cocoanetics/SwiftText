//  EpubArchiveWriter.swift
//  SwiftTextEPUB
//
//  Packages the built EPUB files into the OCF ZIP container. The one hard rule
//  the format adds over an ordinary zip: the `mimetype` entry must come first
//  and be stored (uncompressed) with no extra field, so a reading system can
//  sniff the media type from a fixed offset before parsing anything. Everything
//  else is deflated, except already-compressed cover images, which are stored.

import Foundation
import SwiftTextZip

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
	/// compression.
	static func write(_ files: [EpubFile], to url: URL) throws {
		try ZipContainerWriter.write(entries(for: files), to: url)
	}

	/// Builds the archive and returns its bytes. Useful for callers (and tests)
	/// that want the EPUB as `Data` rather than on disk.
	static func makeData(_ files: [EpubFile]) throws -> Data {
		try ZipContainerWriter.makeData(entries(for: files))
	}

	/// No ZIP entry carries a timestamp, so the same input always yields
	/// byte-identical output — see ``ZipContainerWriter``. The publication date
	/// lives in the OPF's `dcterms:modified`, which is the one EPUB readers show.
	private static func entries(for files: [EpubFile]) -> [ZipContainerEntry] {
		files.map { ZipContainerEntry(path: $0.path, data: $0.data, stored: $0.compression == .stored) }
	}
}
