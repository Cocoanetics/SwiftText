//  DocxArchiveTestSupport.swift
//  SwiftTextDOCXTests
//
//  Reads a written `.docx` back so tests can assert on its parts. libarchive is
//  a sequential reader with no lookup by name, so the container is slurped once
//  and indexed here — which also keeps the stored order available for tests that
//  care about it.

import Foundation
import Archive

struct DocxArchive {
	/// Regular-file entry paths, in the order they are stored.
	let paths: [String]
	private let parts: [String: Data]

	init(contentsOf url: URL) throws {
		let reader = try ArchiveReader(path: url.path)
		var paths = [String]()
		var parts = [String: Data]()
		try reader.forEachEntry { entry, reader in
			guard entry.fileType == .regular else { return }
			paths.append(entry.pathname)
			parts[entry.pathname] = try reader.readData()
		}
		self.paths = paths
		self.parts = parts
	}

	func data(_ path: String) throws -> Data {
		guard let data = parts[path] else { throw DocxArchiveError.missingPart(path) }
		return data
	}

	func text(_ path: String) throws -> String {
		String(decoding: try data(path), as: UTF8.self)
	}

	func contains(_ path: String) -> Bool {
		parts[path] != nil
	}
}

enum DocxArchiveError: Error, CustomStringConvertible {
	case missingPart(String)

	var description: String {
		switch self {
		case .missingPart(let path): return "missing part \(path)"
		}
	}
}
