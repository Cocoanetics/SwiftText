import Foundation

/// A captured Pages package as data — the "code version" of a template document.
///
/// Each entry is a package-relative path plus its bytes (base64-encoded so the
/// whole template can live in committed Swift source, with nothing bundled at
/// runtime). The writer assembles a new document by taking a template's entries,
/// replacing the body content, regenerating the `Metadata/` identity, and
/// re-zipping. Built-in templates are produced by
/// `Scripts/GeneratePagesTemplate.swift` (see `Generated/`).
struct PagesTemplate {
	/// One package entry: an archive-relative path and its base64-encoded bytes.
	struct Entry {
		let path: String
		let base64: String
	}

	/// Entries in archive order (preserved when re-zipping).
	let entries: [Entry]

	/// The decoded bytes for an entry, or `nil` if the path isn't present.
	func data(for path: String) -> [UInt8]? {
		guard let entry = entries.first(where: { $0.path == path }),
		      let data = Data(base64Encoded: entry.base64.replacingOccurrences(of: "\n", with: "")) else {
			return nil
		}
		return [UInt8](data)
	}
}
