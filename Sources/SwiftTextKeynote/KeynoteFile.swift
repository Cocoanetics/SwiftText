import Foundation

/// A read-only handle on an Apple Keynote (`.key`) presentation, mirroring `PagesFile`
/// and `NumbersFile`: construct with a URL, then ask for the rendering you want. Output
/// is the deck's slide text — titles, body bullets, and presenter notes — for LLM
/// agents and other readers.
public final class KeynoteFile {
	public let url: URL
	public let document: KeynoteDocument

	public init(url: URL) throws {
		self.url = url
		self.document = try KeynoteParser().readDocument(from: url)
	}

	/// Markdown: each slide as a `##` heading (its title, or `Slide N`), its body as
	/// bullet lists, and presenter notes as a blockquote.
	public func markdown() -> String {
		var blocks = [String]()
		for (index, slide) in document.slides.enumerated() {
			var lines = ["## \(slide.title ?? "Slide \(index + 1)")"]
			for entry in slide.body {
				for line in entry.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
					lines.append("- \(line)")
				}
			}
			if let notes = slide.notes, !notes.isEmpty {
				lines.append("")
				for line in notes.split(whereSeparator: \.isNewline) {
					lines.append("> \(line)")
				}
			}
			blocks.append(lines.joined(separator: "\n"))
		}
		return blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n")
	}

	/// The deck as JSON (`KeynoteDocument`) for programmatic / LLM-agent consumption.
	public func json() throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		return String(decoding: try encoder.encode(document), as: UTF8.self)
	}

	/// Plain text: title then body lines per slide, blank line between slides.
	public func plainText() -> String {
		document.slides.map { slide in
			var lines = [String]()
			if let title = slide.title { lines.append(title) }
			lines.append(contentsOf: slide.body)
			return lines.joined(separator: "\n")
		}.joined(separator: "\n\n")
	}
}
