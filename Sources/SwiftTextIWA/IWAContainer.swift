import Foundation
import Archive

/// An error reading an iWork document container.
public enum IWAContainerError: Error, LocalizedError {
	/// A Zip-backed document could not be opened (corrupt, encrypted, or not a Zip).
	case unreadableArchive(URL, Error?)

	public var errorDescription: String? {
		switch self {
		case .unreadableArchive(let url, let underlyingError):
			let suffix = underlyingError.map { ": \($0.localizedDescription)" } ?? ""
			return "Could not read the document archive at \(url.lastPathComponent)\(suffix)"
		}
	}
}

/// Reads entries from an iWork document (`.pages`, `.numbers`, `.key`) regardless
/// of how it is stored.
///
/// iWork writes documents either as a single Zip archive or as a package directory
/// (a folder with the document extension). Both layouts share the same internal
/// paths — `Index/*.iwa` for content, `Data/*` for media — so callers work with
/// logical paths and let this type resolve them.
public enum IWAContainer {
	/// One stored entry: its archive-relative path and its bytes.
	public struct Entry {
		public let path: String
		public let data: Data

		public init(path: String, data: Data) {
			self.path = path
			self.data = data
		}
	}

	/// Returns whether the document at `url` is a package directory rather than
	/// a Zip archive.
	public static func isDirectory(_ url: URL) -> Bool {
		var isDirectory: ObjCBool = false
		FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
		return isDirectory.boolValue
	}

	/// Loads every entry whose path begins with `prefix` and ends with `suffix`.
	///
	/// Three layouts are supported: a flat Zip archive; a package directory with
	/// loose folders (`<bundle>/Index/…`); and a package directory whose index is
	/// itself zipped (`<bundle>/Index.zip`), which iWork uses for some saves.
	/// - Throws: ``IWAContainerError/unreadableArchive(_:_:)`` when a Zip-backed
	///   document cannot be opened.
	public static func entries(at url: URL, prefix: String, suffix: String = "") throws -> [Entry] {
		guard isDirectory(url) else {
			return try archiveEntries(at: url, prefix: prefix, suffix: suffix)
		}

		// Loose folder on disk (e.g. <bundle>/Index/Document.iwa).
		let loose = directoryEntries(at: url, prefix: prefix, suffix: suffix)
		if !loose.isEmpty {
			return loose
		}

		// Otherwise the folder may be stored as a sibling Zip (e.g. Index.zip,
		// whose entries are still pathed "Index/…").
		let zipName = prefix.hasSuffix("/") ? String(prefix.dropLast()) + ".zip" : prefix + ".zip"
		let nestedZip = url.appendingPathComponent(zipName)
		if FileManager.default.fileExists(atPath: nestedZip.path) {
			return try archiveEntries(at: nestedZip, prefix: prefix, suffix: suffix)
		}

		return []
	}

	/// Returns the bytes of a single entry at an exact archive-relative path
	/// (e.g. `index.xml`), or `nil` if it isn't present.
	public static func data(at url: URL, named name: String) -> Data? {
		if isDirectory(url) {
			let fileURL = url.appendingPathComponent(name)
			guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
			return try? Data(contentsOf: fileURL)
		}
		return try? archiveEntries(at: url) { $0 == name }.first?.data
	}

	private static func directoryEntries(at url: URL, prefix: String, suffix: String) -> [Entry] {
		let root = url.appendingPathComponent(prefix, isDirectory: true)
		let fileManager = FileManager.default
		guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
			return []
		}
		var entries = [Entry]()
		for case let fileURL as URL in enumerator {
			let isRegularFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
			guard isRegularFile, fileURL.lastPathComponent.hasSuffix(suffix) else { continue }
			guard let data = try? Data(contentsOf: fileURL) else { continue }
			entries.append(Entry(path: prefix + fileURL.lastPathComponent, data: data))
		}
		// Stable order so multi-file documents parse deterministically.
		return entries.sorted { $0.path < $1.path }
	}

	private static func archiveEntries(at url: URL, prefix: String, suffix: String) throws -> [Entry] {
		try archiveEntries(at: url) { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
	}

	/// Streams the Zip at `url` once, keeping the regular-file entries whose path
	/// `isWanted` accepts. libarchive is a sequential reader — there is no random
	/// access by name — so every lookup is a single pass in stored order.
	private static func archiveEntries(at url: URL, where isWanted: (String) -> Bool) throws -> [Entry] {
		let reader: ArchiveReader
		do {
			reader = try ArchiveReader(path: url.path)
		} catch {
			throw IWAContainerError.unreadableArchive(url, error)
		}
		var entries = [Entry]()
		do {
			try reader.forEachEntry { entry, reader in
				guard entry.fileType == .regular, isWanted(entry.pathname) else { return }
				entries.append(Entry(path: entry.pathname, data: try reader.readData()))
			}
		} catch {
			throw IWAContainerError.unreadableArchive(url, error)
		}
		return entries
	}
}
