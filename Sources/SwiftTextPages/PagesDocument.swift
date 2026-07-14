import Foundation
import Markdown

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
		/// Hyperlink ranges over `text`, rendered as `[text](url)` in Markdown.
		public var links: [LinkRun]
		/// The list nesting level (0-based) when this paragraph is a list item,
		/// else `nil`.
		public var listLevel: Int?
		/// Whether the list item is ordered (numbered) rather than a bullet.
		public var listOrdered: Bool
		/// Footnote reference markers within the paragraph, by paragraph-relative
		/// UTF-16 offset, sorted. Each becomes `[^number]` in Markdown.
		public var footnoteMarkers: [FootnoteMarker]
		/// Native tables anchored in this paragraph, in anchor order; rendered as
		/// Markdown tables.
		public var tables: [Table]
		/// Whether this paragraph belongs to a preformatted code block (the "Code
		/// Block" style). Consecutive code-block paragraphs render as one fenced block.
		public var isCodeBlock: Bool

		/// A native table reconstructed from the iWork grid: cell strings (row 0 =
		/// header) plus per-column horizontal alignment.
		public struct Table {
			public enum ColumnAlignment: Sendable { case left, center, right }
			public var cells: [[String]]
			public var columnAlignments: [ColumnAlignment]
			public init(cells: [[String]], columnAlignments: [ColumnAlignment] = []) {
				self.cells = cells
				self.columnAlignments = columnAlignments
			}
		}

		public init(
			text: String,
			fontSize: Double? = nil,
			bold: Bool = false,
			headingLevel: Int? = nil,
			attachmentReferences: [String?] = [],
			emphasis: [EmphasisSpan] = [],
			links: [LinkRun] = [],
			listLevel: Int? = nil,
			listOrdered: Bool = false,
			footnoteMarkers: [FootnoteMarker] = [],
			tables: [Table] = [],
			isCodeBlock: Bool = false
		) {
			self.text = text
			self.fontSize = fontSize
			self.bold = bold
			self.headingLevel = headingLevel
			self.attachmentReferences = attachmentReferences
			self.emphasis = emphasis
			self.links = links
			self.listLevel = listLevel
			self.listOrdered = listOrdered
			self.footnoteMarkers = footnoteMarkers
			self.tables = tables
			self.isCodeBlock = isCodeBlock
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
			public var code: Bool

			public init(start: Int, bold: Bool, italic: Bool, strike: Bool = false, code: Bool = false) {
				self.start = start
				self.bold = bold
				self.italic = italic
				self.strike = strike
				self.code = code
			}
		}

		/// A hyperlink covering a paragraph-relative UTF-16 range `[start, end)`,
		/// rendered as `[text](url)`. Recovered from the storage's smart-field run
		/// table (`#11`) and the referenced `TSWP` hyperlink objects (type 2032).
		public struct LinkRun {
			public var start: Int
			public var end: Int
			public var url: String

			public init(start: Int, end: Int, url: String) {
				self.start = start
				self.end = end
				self.url = url
			}
		}

		/// Renders the paragraph text: soft line breaks become newlines and
		/// surrounding whitespace is trimmed. When `applyingEmphasis` is set, runs
		/// are wrapped in `**`/`*`/`***`; when `inliningImages` is set, image
		/// anchors become `![](reference)` (both off for plain text).
		/// `suppressingUniformEmphasis` drops any emphasis that covers the entire
		/// paragraph uniformly — that styling restates the paragraph's own style
		/// (a bold heading style, say) rather than marking up a span within it, so
		/// headings render as `## Section`, not `## **Section**`; spans that
		/// differ from the rest still get their markers.
		func renderedText(inliningImages: Bool, applyingEmphasis: Bool, suppressingUniformEmphasis: Bool = false) -> String {
			var suppressBold = false
			var suppressItalic = false
			var suppressStrike = false
			var suppressCode = false
			if suppressingUniformEmphasis, let first = emphasis.first, first.start <= 0 {
				suppressBold = emphasis.allSatisfy(\.bold)
				suppressItalic = emphasis.allSatisfy(\.italic)
				suppressStrike = emphasis.allSatisfy(\.strike)
				suppressCode = emphasis.allSatisfy(\.code)
			}

			var output = ""
			var runText = ""
			var runBold = false
			var runItalic = false
			var runStrike = false
			var runCode = false
			var anchorIndex = 0
			var relativeOffset = 0
			var spanIndex = 0
			var footnoteIndex = 0
			var activeBold = false
			var activeItalic = false
			var activeStrike = false
			var activeCode = false

			// Hyperlink ranges, applied as `[text](url)` in Markdown. Tracked alongside
			// emphasis: entering a link emits `[`, leaving it emits `](url)`.
			let sortedLinks = applyingEmphasis ? links.sorted { $0.start < $1.start } : []
			var linkIndex = 0
			var activeLinkEnd: Int?
			var activeLinkURL = ""

			func flushRun() {
				guard !runText.isEmpty else { return }
				output += applyingEmphasis
					? PagesDocument.markedUp(
						runText,
						bold: runBold && !suppressBold,
						italic: runItalic && !suppressItalic,
						strike: runStrike && !suppressStrike,
						code: runCode && !suppressCode
					)
					: runText
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
					activeCode = emphasis[spanIndex].code
					spanIndex += 1
				}
				// Close a finished link, then open a new one starting here.
				if let end = activeLinkEnd, relativeOffset >= end {
					flushRun()
					output += "](\(activeLinkURL))"
					activeLinkEnd = nil
				}
				while linkIndex < sortedLinks.count, sortedLinks[linkIndex].start <= relativeOffset {
					let link = sortedLinks[linkIndex]
					linkIndex += 1
					if activeLinkEnd == nil, link.end > relativeOffset {
						flushRun()
						output += "["
						activeLinkEnd = link.end
						activeLinkURL = link.url
					}
				}
				emitFootnotes(upTo: relativeOffset)
				let width = scalar.value > 0xFFFF ? 2 : 1
				switch scalar {
				case "\u{2028}":
					flushRun()
					output += "\n"
				case "\u{000E}":
					// Footnote reference character — the `[^n]` marker is emitted separately
					// (see emitFootnotes), so drop the placeholder char itself.
					break
				case "\u{FFFC}":
					flushRun()
					if inliningImages, anchorIndex < attachmentReferences.count,
					   let reference = attachmentReferences[anchorIndex] {
						output += "![](\(reference))"
					}
					anchorIndex += 1
				default:
					if applyingEmphasis, activeBold != runBold || activeItalic != runItalic || activeStrike != runStrike || activeCode != runCode {
						flushRun()
						runBold = activeBold
						runItalic = activeItalic
						runStrike = activeStrike
						runCode = activeCode
					}
					runText.unicodeScalars.append(scalar)
				}
				relativeOffset += width
			}
			emitFootnotes(upTo: relativeOffset)
			flushRun()
			// A link that runs to the end of the paragraph still needs its closer.
			if activeLinkEnd != nil { output += "](\(activeLinkURL))" }
			return output
				.replacingOccurrences(of: "\t", with: "    ")
				.trimmingCharacters(in: .whitespacesAndNewlines)
		}

		/// The plain-text form: soft breaks normalized, emphasis and inline
		/// attachments removed.
		public func normalizedText() -> String {
			renderedText(inliningImages: false, applyingEmphasis: false)
		}

		/// The literal text for a fenced code block: soft line breaks (U+2028) become
		/// newlines, but indentation is preserved — unlike `normalizedText()`, which
		/// trims surrounding whitespace (fatal for code).
		public func codeText() -> String {
			String(String.UnicodeScalarView(text.unicodeScalars.map { $0 == "\u{2028}" ? "\n" : $0 }))
		}
	}

	/// Wraps `text`'s non-whitespace core in the Markdown emphasis markers for the
	/// given styling, keeping leading/trailing whitespace outside the markers.
	/// Strikethrough (`~~`) wraps any bold/italic markers.
	static func markedUp(_ text: String, bold: Bool, italic: Bool, strike: Bool, code: Bool = false) -> String {
		guard bold || italic || strike || code else { return text }
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
		// Inline code is literal in Markdown, so backticks go innermost; emphasis wraps it.
		if code {
			core = "`\(core)`"
		}
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

	/// Returns the normalized text of each non-empty paragraph. List items keep
	/// their visible marker — the number or bullet Pages draws is document
	/// content, so plain-text extraction would otherwise silently drop it
	/// ("Topics: 1. Offer 2. Acceptance" must not flatten into bare lines).
	/// Numbering follows the same counter rules as `markdown()`.
	public func plainTextParagraphs() -> [String] {
		var out = [String]()
		var counters = [Int: Int]()
		for paragraph in paragraphs {
			let text = paragraph.normalizedText()
			guard !text.isEmpty else { continue }
			guard let level = paragraph.listLevel else {
				counters.removeAll()
				out.append(text)
				continue
			}
			let indent = String(repeating: "    ", count: max(level, 0))
			for deeper in counters.keys where deeper > level { counters[deeper] = nil }
			if paragraph.listOrdered {
				counters[level, default: 0] += 1
				out.append(indent + "\(counters[level]!). " + text)
			} else {
				out.append(indent + "• " + text)
			}
		}
		return out
	}

	/// Returns the document as plain text, paragraphs separated by blank lines.
	public func plainText() -> String {
		plainTextParagraphs().joined(separator: "\n\n")
	}

	/// Returns the document as Markdown.
	///
	/// The decoded structure is also available as a swift-markdown AST via
	/// `markdownDocument()` (the inverse of `MarkdownToPages`, which walks an AST to
	/// generate Pages) — use that to compose with the HTML/DOCX renderers or any other
	/// AST consumer. This convenience serializer is kept hand-rolled rather than going
	/// through `MarkupFormatter` because cmark emits non-standard single-tilde
	/// strikethrough (`~x~`) and width-padded table cells; this keeps `~~`/`*`/`` ` ``
	/// and clean GFM tables.
	public func markdown() -> String {
		let bodySize = dominantBodyFontSize()
		var lines = [String]()
		var isListItem = [Bool]()
		var counters = [Int: Int]()

		var index = 0
		while index < paragraphs.count {
			let paragraph = paragraphs[index]
			// Native tables anchored in this paragraph render as Markdown table blocks.
			for table in paragraph.tables where !table.cells.isEmpty {
				lines.append(Self.markdownTable(table))
				isListItem.append(false)
			}

			// A run of code-block paragraphs becomes one fenced block; use the raw
			// (un-marked-up) text so indentation and literal characters survive.
			if paragraph.isCodeBlock {
				var codeLines = [String]()
				while index < paragraphs.count, paragraphs[index].isCodeBlock {
					codeLines.append(paragraphs[index].codeText())
					index += 1
				}
				counters.removeAll()
				lines.append("```\n" + codeLines.joined(separator: "\n") + "\n```")
				isListItem.append(false)
				continue
			}

			let rendered = paragraph.renderedText(inliningImages: true, applyingEmphasis: true)
			guard !rendered.isEmpty else { index += 1; continue }

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
					let heading = paragraph.renderedText(inliningImages: true, applyingEmphasis: true, suppressingUniformEmphasis: true)
					lines.append(String(repeating: "#", count: level) + " " + heading)
				} else {
					lines.append(rendered)
				}
				isListItem.append(false)
			}
			index += 1
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

	/// Renders a table (row 0 = header) as a GitHub-flavored Markdown table, with the
	/// delimiter row encoding each column's alignment (`:--`, `:-:`, `--:`).
	static func markdownTable(_ table: Paragraph.Table) -> String {
		let grid = table.cells
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
		func delimiter(_ column: Int) -> String {
			switch column < table.columnAlignments.count ? table.columnAlignments[column] : .left {
			case .left: return "---"
			case .center: return ":-:"
			case .right: return "--:"
			}
		}
		var lines = [row(grid[0])]
		lines.append("| " + (0..<columns).map(delimiter).joined(separator: " | ") + " |")
		for bodyRow in grid.dropFirst() { lines.append(row(bodyRow)) }
		return lines.joined(separator: "\n")
	}

	/// The most common font size across body text, weighted by paragraph length.
	/// This is the baseline that headings are measured against.
	func dominantBodyFontSize() -> Double? {
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
	func headingLevel(for paragraph: PagesDocument.Paragraph, text: String, bodySize: Double?) -> Int? {
		// An explicit level read from the paragraph's style is authoritative — honor it
		// regardless of length (a styled heading is a heading even if it's long).
		if let explicit = paragraph.headingLevel, !text.isEmpty {
			return max(1, min(explicit, 6))
		}

		// Otherwise fall back to typography: a heading must be short and single-line so
		// emphasized-but-long body paragraphs aren't promoted.
		guard !text.isEmpty, text.count <= 200, !text.contains("\n") else {
			return nil
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
