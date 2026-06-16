import Foundation

/// A parsed Pages document reduced to its ordered body paragraphs.
///
/// Pages stores no explicit "heading" flag the way DOCX does (its style names
/// are localized — "Heading", "Überschrift", "Titre"…), so structure is
/// recovered from typography: a short paragraph set in a font noticeably larger
/// than the document's dominant body size is treated as a heading, with the
/// level derived from how much larger it is. When no style information is
/// available every paragraph renders as plain body text.
public struct PagesDocument {
	/// The body paragraphs in document order.
	public internal(set) var paragraphs: [Paragraph] = []

	/// The document's placed content images, in stable order. Each carries the
	/// `referenceName` used in Markdown image links and when extracting to disk.
	public internal(set) var imageAssets: [ImageAsset] = []

	/// The document's footnotes, numbered in reading order. Rendered as
	/// `[^N]: text` definitions at the end of the Markdown.
	public internal(set) var footnotes: [Footnote] = []

	public init() {}

	public init(paragraphs: [Paragraph], imageAssets: [ImageAsset] = [], footnotes: [Footnote] = []) {
		self.paragraphs = paragraphs
		self.imageAssets = imageAssets
		self.footnotes = footnotes
	}

	/// A footnote's number and its (single-line) text.
	public struct Footnote {
		public let number: Int
		public let text: String

		public init(number: Int, text: String) {
			self.number = number
			self.text = text
		}
	}

	/// A placed content image and the name used to reference it.
	public struct ImageAsset {
		/// The cleaned, document-unique name used in Markdown (`![](referenceName)`)
		/// and as the output file name when extracting.
		public let referenceName: String
		/// The image's file name inside the package's `Data/` folder.
		public let dataFileName: String

		public init(referenceName: String, dataFileName: String) {
			self.referenceName = referenceName
			self.dataFileName = dataFileName
		}
	}

	/// A single paragraph of body text plus the typographic hints used to infer
	/// structure.
	public struct Paragraph {
		/// The raw paragraph text. May contain U+2028 (line separator) for soft
		/// line breaks and U+FFFC (object replacement) for inline attachments.
		public var text: String
		/// The resolved font size of the paragraph's style, if known. Used by the
		/// modern (`.iwa`) reader, where heading levels are inferred from typography.
		public var fontSize: Double?
		/// Whether the paragraph's style is bold.
		public var bold: Bool
		/// An explicit heading level (1–6). The legacy (`index.xml`) reader sets
		/// this from the paragraph's style name ("Heading 2", "Title", …); when set
		/// it takes precedence over the font-size heuristic.
		public var headingLevel: Int?
		/// The image reference name for each inline-attachment anchor (`U+FFFC`) in
		/// `text`, in order. `nil` marks a non-image attachment (text box, smart
		/// field, …) so it renders as nothing.
		public var attachmentReferences: [String?]
		/// Character-emphasis spans over `text`, sorted by `start` (a paragraph-
		/// relative UTF-16 offset); each applies until the next span.
		public var emphasis: [EmphasisSpan]
		/// The list nesting level (0-based) when this paragraph is a list item,
		/// else `nil`.
		public var listLevel: Int?
		/// Whether the list item is ordered (numbered) rather than a bullet.
		public var listOrdered: Bool
		/// Footnote reference markers within the paragraph, by paragraph-relative
		/// UTF-16 offset, sorted. Each becomes `[^number]` in Markdown.
		public var footnoteMarkers: [FootnoteMarker]
		/// Native tables anchored in this paragraph, in anchor order. Each is a grid
		/// of cell strings (row 0 = header row); rendered as a Markdown table.
		public var tables: [[[String]]]

		public init(
			text: String,
			fontSize: Double? = nil,
			bold: Bool = false,
			headingLevel: Int? = nil,
			attachmentReferences: [String?] = [],
			emphasis: [EmphasisSpan] = [],
			listLevel: Int? = nil,
			listOrdered: Bool = false,
			footnoteMarkers: [FootnoteMarker] = [],
			tables: [[[String]]] = []
		) {
			self.text = text
			self.fontSize = fontSize
			self.bold = bold
			self.headingLevel = headingLevel
			self.attachmentReferences = attachmentReferences
			self.emphasis = emphasis
			self.listLevel = listLevel
			self.listOrdered = listOrdered
			self.footnoteMarkers = footnoteMarkers
			self.tables = tables
		}

		/// A footnote reference at a paragraph-relative UTF-16 offset.
		public struct FootnoteMarker {
			public var offset: Int
			public var number: Int

			public init(offset: Int, number: Int) {
				self.offset = offset
				self.number = number
			}
		}

		/// A run of characters with uniform emphasis, starting at a paragraph-
		/// relative UTF-16 offset.
		public struct EmphasisSpan {
			public var start: Int
			public var bold: Bool
			public var italic: Bool
			public var strike: Bool

			public init(start: Int, bold: Bool, italic: Bool, strike: Bool = false) {
				self.start = start
				self.bold = bold
				self.italic = italic
				self.strike = strike
			}
		}

		/// Renders the paragraph text: soft line breaks become newlines and
		/// surrounding whitespace is trimmed. When `applyingEmphasis` is set, runs
		/// are wrapped in `**`/`*`/`***`; when `inliningImages` is set, image
		/// anchors become `![](reference)` (both off for plain text).
		func renderedText(inliningImages: Bool, applyingEmphasis: Bool) -> String {
			var output = ""
			var runText = ""
			var runBold = false
			var runItalic = false
			var runStrike = false
			var anchorIndex = 0
			var relativeOffset = 0
			var spanIndex = 0
			var footnoteIndex = 0
			var activeBold = false
			var activeItalic = false
			var activeStrike = false

			func flushRun() {
				guard !runText.isEmpty else { return }
				output += applyingEmphasis ? PagesDocument.markedUp(runText, bold: runBold, italic: runItalic, strike: runStrike) : runText
				runText = ""
			}

			// Footnote references render only in Markdown (when emphasis is applied).
			func emitFootnotes(upTo offset: Int) {
				guard applyingEmphasis else { return }
				while footnoteIndex < footnoteMarkers.count, footnoteMarkers[footnoteIndex].offset <= offset {
					flushRun()
					output += "[^\(footnoteMarkers[footnoteIndex].number)]"
					footnoteIndex += 1
				}
			}

			for scalar in text.unicodeScalars {
				while spanIndex < emphasis.count, emphasis[spanIndex].start <= relativeOffset {
					activeBold = emphasis[spanIndex].bold
					activeItalic = emphasis[spanIndex].italic
					activeStrike = emphasis[spanIndex].strike
					spanIndex += 1
				}
				emitFootnotes(upTo: relativeOffset)
				let width = scalar.value > 0xFFFF ? 2 : 1
				switch scalar {
				case "\u{2028}":
					flushRun()
					output += "\n"
				case "\u{FFFC}":
					flushRun()
					if inliningImages, anchorIndex < attachmentReferences.count,
					   let reference = attachmentReferences[anchorIndex] {
						output += "![](\(reference))"
					}
					anchorIndex += 1
				default:
					if applyingEmphasis, activeBold != runBold || activeItalic != runItalic || activeStrike != runStrike {
						flushRun()
						runBold = activeBold
						runItalic = activeItalic
						runStrike = activeStrike
					}
					runText.unicodeScalars.append(scalar)
				}
				relativeOffset += width
			}
			emitFootnotes(upTo: relativeOffset)
			flushRun()
			return output
				.replacingOccurrences(of: "\t", with: "    ")
				.trimmingCharacters(in: .whitespacesAndNewlines)
		}

		/// The plain-text form: soft breaks normalized, emphasis and inline
		/// attachments removed.
		public func normalizedText() -> String {
			renderedText(inliningImages: false, applyingEmphasis: false)
		}
	}

	/// Wraps `text`'s non-whitespace core in the Markdown emphasis markers for the
	/// given styling, keeping leading/trailing whitespace outside the markers.
	/// Strikethrough (`~~`) wraps any bold/italic markers.
	static func markedUp(_ text: String, bold: Bool, italic: Bool, strike: Bool) -> String {
		guard bold || italic || strike else { return text }
		let scalars = Array(text.unicodeScalars)
		var start = 0
		while start < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[start]) {
			start += 1
		}
		var end = scalars.count
		while end > start, CharacterSet.whitespacesAndNewlines.contains(scalars[end - 1]) {
			end -= 1
		}
		guard start < end else { return text }
		var core = String(String.UnicodeScalarView(scalars[start..<end]))
		if bold && italic {
			core = "***\(core)***"
		} else if bold {
			core = "**\(core)**"
		} else if italic {
			core = "*\(core)*"
		}
		if strike {
			core = "~~\(core)~~"
		}
		let leading = String(String.UnicodeScalarView(scalars[..<start]))
		let trailing = String(String.UnicodeScalarView(scalars[end...]))
		return leading + core + trailing
	}

	/// Returns the normalized text of each non-empty paragraph.
	public func plainTextParagraphs() -> [String] {
		paragraphs.map { $0.normalizedText() }.filter { !$0.isEmpty }
	}

	/// Returns the document as plain text, paragraphs separated by blank lines.
	public func plainText() -> String {
		plainTextParagraphs().joined(separator: "\n\n")
	}

	/// Returns the document as Markdown: inline bold/italic, headings inferred
	/// from font size, bullet/numbered lists, and inline image links.
	public func markdown() -> String {
		let bodySize = dominantBodyFontSize()
		var lines = [String]()
		var isListItem = [Bool]()
		var counters = [Int: Int]()

		for paragraph in paragraphs {
			// Native tables anchored in this paragraph render as Markdown table blocks.
			for table in paragraph.tables where !table.isEmpty {
				lines.append(Self.markdownTable(table))
				isListItem.append(false)
			}

			let rendered = paragraph.renderedText(inliningImages: true, applyingEmphasis: true)
			guard !rendered.isEmpty else { continue }

			if let level = paragraph.listLevel {
				let indent = String(repeating: "  ", count: max(level, 0))
				let marker: String
				if paragraph.listOrdered {
					counters[level, default: 0] += 1
					for deeper in counters.keys where deeper > level { counters[deeper] = nil }
					marker = "\(counters[level]!). "
				} else {
					for deeper in counters.keys where deeper > level { counters[deeper] = nil }
					marker = "- "
				}
				lines.append(indent + marker + rendered)
				isListItem.append(true)
			} else {
				counters.removeAll()
				let plain = paragraph.normalizedText()
				if let level = headingLevel(for: paragraph, text: plain, bodySize: bodySize) {
					lines.append(String(repeating: "#", count: level) + " " + rendered)
				} else {
					lines.append(rendered)
				}
				isListItem.append(false)
			}
		}

		// Consecutive list items are kept tight (single newline); everything else
		// is separated by a blank line.
		var output = ""
		for (index, line) in lines.enumerated() {
			if index > 0 {
				output += (isListItem[index] && isListItem[index - 1]) ? "\n" : "\n\n"
			}
			output += line
		}

		// Footnote definitions follow the body, one per line.
		if !footnotes.isEmpty {
			let definitions = footnotes
				.sorted { $0.number < $1.number }
				.map { "[^\($0.number)]: \($0.text)" }
				.joined(separator: "\n")
			output += (output.isEmpty ? "" : "\n\n") + definitions
		}
		return output
	}

	/// Renders a cell grid (row 0 = header) as a GitHub-flavored Markdown table.
	static func markdownTable(_ grid: [[String]]) -> String {
		let columns = grid.map(\.count).max() ?? 0
		guard columns > 0 else { return "" }
		func cell(_ value: String) -> String {
			value.replacingOccurrences(of: "\n", with: " ")
				.replacingOccurrences(of: "|", with: "\\|")
				.trimmingCharacters(in: .whitespaces)
		}
		func row(_ cells: [String]) -> String {
			let padded = (0..<columns).map { $0 < cells.count ? cell(cells[$0]) : "" }
			return "| " + padded.joined(separator: " | ") + " |"
		}
		var lines = [row(grid[0])]
		lines.append("| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |")
		for bodyRow in grid.dropFirst() { lines.append(row(bodyRow)) }
		return lines.joined(separator: "\n")
	}

	/// The most common font size across body text, weighted by paragraph length.
	/// This is the baseline that headings are measured against.
	private func dominantBodyFontSize() -> Double? {
		var weights = [Double: Int]()
		for paragraph in paragraphs {
			guard let size = paragraph.fontSize else { continue }
			let length = paragraph.normalizedText().count
			guard length > 0 else { continue }
			weights[size, default: 0] += length
		}
		return weights.max { $0.value < $1.value }?.key
	}

	/// Infers a heading level (1–6) for a paragraph, or `nil` for body text.
	///
	/// A heading must be short and occupy a single line — this keeps
	/// emphasized-but-long body paragraphs from being promoted. An explicit level
	/// (from a legacy style name) is honored directly; otherwise the level is
	/// derived from how much larger than the body the paragraph is set.
	private func headingLevel(for paragraph: PagesDocument.Paragraph, text: String, bodySize: Double?) -> Int? {
		guard !text.isEmpty, text.count <= 200, !text.contains("\n") else {
			return nil
		}

		if let explicit = paragraph.headingLevel {
			return max(1, min(explicit, 6))
		}

		guard
			let bodySize, bodySize > 0,
			let size = paragraph.fontSize,
			size > bodySize * 1.15,
			text.count <= 140
		else {
			return nil
		}

		let ratio = size / bodySize
		if ratio >= 1.8 {
			return 1
		} else if ratio >= 1.4 {
			return 2
		} else {
			return 3
		}
	}
}
