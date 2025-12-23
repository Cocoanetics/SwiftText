import Foundation
import ZIPFoundation

/// A parsed DOCX file with convenience helpers for plain text or Markdown output.
public final class DocxFile {
	/// The URL of the DOCX file on disk.
	public let url: URL

	/// The parsed document model.
	public let document: DocxDocument

	/// Creates a DocxFile by reading and parsing the DOCX at the given URL.
	/// - Parameter url: The file URL pointing to the DOCX archive.
	/// - Throws: A ``DocxFileError`` describing the failure reason.
	public init(url: URL) throws {
		self.url = url
		self.document = try DocxParser().readDocument(from: url)
	}

	/// Returns the plain text for each paragraph with formatting removed.
	public func plainTextParagraphs() -> [String] {
		document.plainTextParagraphs()
	}

	/// Returns a single plain text string with paragraph spacing applied.
	public func plainText() -> String {
		let paragraphs = document.renderedParagraphs(style: .plainText)
		return DocxTextOutput.join(paragraphs)
	}

	/// Returns rendered paragraphs suitable for Markdown output.
	public func markdownParagraphs() -> [DocxDocument.RenderedParagraph] {
		document.markdownParagraphs()
	}

	/// Returns a Markdown string with headings, lists, and inline emphasis.
	public func markdown() -> String {
		let paragraphs = document.renderedParagraphs(style: .markdown)
		return DocxTextOutput.join(paragraphs)
	}

	/// Extracts embedded images from the DOCX archive to the given directory.
	/// Images are deduplicated by file name within the archive.
	/// - Parameter directory: The destination directory. Defaults to the current working directory.
	/// - Returns: The URLs of the extracted images on disk.
	/// - Throws: A ``DocxFileError`` describing the failure reason.
	public func extractImages(to directory: URL? = nil) throws -> [URL] {
		guard FileManager.default.fileExists(atPath: url.path) else {
			throw DocxFileError.fileNotFound(url)
		}
		let archive: Archive
		do {
			archive = try Archive(url: url, accessMode: .read)
		} catch {
			throw DocxFileError.unreadableArchive(url, error)
		}

		let destination = directory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
		try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

		var extracted = [URL]()
		var seenNames: [String: URL] = [:]
		for entry in archive {
			guard entry.path.hasPrefix("word/media/"), !entry.path.hasSuffix("/") else { continue }
			let fileName = URL(fileURLWithPath: entry.path).lastPathComponent
			if let existing = seenNames[fileName] {
				extracted.append(existing)
				continue
			}
			var data = Data()
			_ = try archive.extract(entry) { data.append($0) }
			let outputURL = uniqueDestinationURL(for: fileName, in: destination)
			try data.write(to: outputURL, options: .atomic)
			seenNames[fileName] = outputURL
			extracted.append(outputURL)
		}

		return extracted
	}
}

/// Errors that can occur while reading a DOCX file.
public enum DocxFileError: Error, LocalizedError {
	case fileNotFound(URL)
	case unreadableArchive(URL, Error?)
	case missingDocumentXML
	case documentXMLParsingFailed(Error?)
	case stylesParsingFailed(Error?)
	case numberingParsingFailed(Error?)

	public var errorDescription: String? {
		switch self {
		case .fileNotFound(let url):
			return "DOCX file not found at \(url.path)"
		case .unreadableArchive(let url, let underlyingError):
			if let underlyingError {
				return "Unable to open DOCX archive at \(url.path): \(underlyingError.localizedDescription)"
			}
			return "Unable to open DOCX archive at \(url.path)"
		case .missingDocumentXML:
			return "DOCX archive lacks word/document.xml"
		case .documentXMLParsingFailed(let error):
			guard let error else {
				return "Failed to parse word/document.xml"
			}
			return "Failed to parse word/document.xml: \(error.localizedDescription)"
		case .stylesParsingFailed(let error):
			guard let error else {
				return "Failed to parse word/styles.xml"
			}
			return "Failed to parse word/styles.xml: \(error.localizedDescription)"
		case .numberingParsingFailed(let error):
			guard let error else {
				return "Failed to parse word/numbering.xml"
			}
			return "Failed to parse word/numbering.xml: \(error.localizedDescription)"
		}
	}
}

private enum DocxTextOutput {
	static func join(_ paragraphs: [DocxDocument.RenderedParagraph]) -> String {
		guard !paragraphs.isEmpty else {
			return ""
		}
		var builder = ""
		for (index, paragraph) in paragraphs.enumerated() {
			if index > 0 {
				let previous = paragraphs[index - 1]
				if paragraph.isListItem && previous.isListItem {
					builder += "\n"
				} else {
					builder += "\n\n"
				}
			}
			builder += paragraph.text
		}
		return builder
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
