import Foundation
import Markdown

/// A parsed Pages (`.pages`) document with convenience helpers for plain text
/// or Markdown output.
///
/// Pages files are Zip archives containing an `Index/` folder of iWork Archive
/// (`.iwa`) objects. Everything needed to read them — Zip access (via
/// ZIPFoundation), Snappy decompression, and Protocol Buffers decoding — is
/// implemented in this module, so no external tooling or Apple frameworks are
/// required and the same code runs on every platform.
public final class PagesFile {
	/// The URL of the Pages file on disk.
	public let url: URL

	/// The parsed document model.
	public let document: PagesDocument

	/// Creates a `PagesFile` by reading and parsing the document at the given URL.
	/// - Parameter url: The file URL pointing to the `.pages` archive.
	/// - Throws: A ``PagesFileError`` describing the failure reason.
	public init(url: URL) throws {
		self.url = url
		self.document = try PagesParser().readDocument(from: url)
	}

	/// Returns the normalized text of each non-empty paragraph.
	public func plainTextParagraphs() -> [String] {
		document.plainTextParagraphs()
	}

	/// Returns the document as plain text with paragraph spacing applied.
	public func plainText() -> String {
		document.plainText()
	}

	/// Returns a Markdown string with headings inferred from the document's
	/// typography.
	public func markdown() -> String {
		document.markdown()
	}

	/// Returns the document as a swift-markdown AST (`Markdown.Document`) — the inverse
	/// of `MarkdownToPages`, which walks an AST to generate Pages. Use this to feed the
	/// HTML/DOCX renderers or any other AST consumer; `markdown()` is the string form.
	public func markdownDocument() -> Markdown.Document {
		document.markdownDocument()
	}

	/// Extracts the document's embedded content images to the given directory.
	///
	/// Pages keeps all media in the package's `Data/` folder, but mixes the user's
	/// placed images with downscaled previews (`…-small….png`) and theme
	/// decorations (preset image fills, list-bullet glyphs). By default only the
	/// placed content images are exported, each under the same cleaned, unique
	/// name used in the Markdown image links (so `![](name)` resolves to the file
	/// written here). The `preview*.jpg` thumbnails Pages writes for
	/// Finder/QuickLook live outside `Data/` and are never considered.
	/// - Parameters:
	///   - directory: The destination directory. Defaults to the current working
	///     directory.
	///   - includingThumbnailsAndAssets: When `true`, also export the downscaled
	///     previews and theme/template assets, under their original file names.
	/// - Returns: The URLs of the extracted images on disk.
	/// - Throws: A ``PagesFileError`` describing the failure reason.
	@discardableResult
	public func extractImages(to directory: URL? = nil, includingThumbnailsAndAssets: Bool = false) throws -> [URL] {
		guard FileManager.default.fileExists(atPath: url.path) else {
			throw PagesFileError.fileNotFound(url)
		}
		let destination = directory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
		try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

		// Preferred path: the parsed document already identified the content images
		// (via the registry) and assigned each the reference name used in Markdown.
		if !includingThumbnailsAndAssets, !document.imageAssets.isEmpty {
			let dataByName = try mediaDataByFileName()
			var extracted = [URL]()
			for asset in document.imageAssets {
				guard let data = dataByName[asset.dataFileName] else { continue }
				let outputURL = uniqueDestinationURL(for: asset.referenceName, in: destination)
				try data.write(to: outputURL, options: .atomic)
				extracted.append(outputURL)
			}
			return extracted
		}

		// Fallback (no registry, e.g. legacy) and the include-everything mode:
		// list the `Data/` folder directly.
		var extracted = [URL]()
		for entry in try PagesContainer.entries(at: url, prefix: "Data/") {
			let fileName = URL(fileURLWithPath: entry.path).lastPathComponent
			guard PagesImageCatalog.isImageName(fileName) else { continue }
			if !includingThumbnailsAndAssets,
			   PagesImageCatalog.isThumbnail(fileName) || PagesImageCatalog.isDecorativeAsset(fileName) {
				continue
			}
			let outputName = includingThumbnailsAndAssets ? fileName : PagesImageCatalog.logicalName(fileName)
			let outputURL = uniqueDestinationURL(for: outputName, in: destination)
			try entry.data.write(to: outputURL, options: .atomic)
			extracted.append(outputURL)
		}
		return extracted
	}

	/// The bytes of every file in the package's `Data/` folder, keyed by file name.
	private func mediaDataByFileName() throws -> [String: Data] {
		var result = [String: Data]()
		for entry in try PagesContainer.entries(at: url, prefix: "Data/") {
			result[URL(fileURLWithPath: entry.path).lastPathComponent] = entry.data
		}
		return result
	}
}

/// Errors that can occur while reading a Pages file.
public enum PagesFileError: Error, LocalizedError {
	case fileNotFound(URL)
	case unreadableArchive(URL, Error?)
	case notAnIWorkDocument(URL)
	case legacyGzipUnsupported(URL)
	case legacyXMLParsingFailed(Error?)

	public var errorDescription: String? {
		switch self {
		case .fileNotFound(let url):
			return "Pages file not found at \(url.path)"
		case .unreadableArchive(let url, let underlyingError):
			if let underlyingError {
				return "Unable to open Pages archive at \(url.path): \(underlyingError.localizedDescription)"
			}
			return "Unable to open Pages archive at \(url.path)"
		case .notAnIWorkDocument(let url):
			return "Not a Pages document (no Index/*.iwa objects and no index.xml) at \(url.path)"
		case .legacyGzipUnsupported(let url):
			return "Pages document at \(url.path) stores a gzipped legacy index (index.xml.gz), which is not supported."
		case .legacyXMLParsingFailed(let error):
			if let error {
				return "Failed to parse legacy Pages index.xml: \(error.localizedDescription)"
			}
			return "Failed to parse legacy Pages index.xml"
		}
	}
}

private func uniqueDestinationURL(for fileName: String, in directory: URL) -> URL {
	let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
	let ext = URL(fileURLWithPath: fileName).pathExtension
	var candidate = directory.appendingPathComponent(fileName)
	var counter = 1
	while FileManager.default.fileExists(atPath: candidate.path) {
		let suffix = "\(base)-\(counter)"
		if ext.isEmpty {
			candidate = directory.appendingPathComponent(suffix)
		} else {
			candidate = directory.appendingPathComponent(suffix).appendingPathExtension(ext)
		}
		counter += 1
	}
	return candidate
}
