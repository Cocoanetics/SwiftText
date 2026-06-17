/// A platform-independent attributed-text value type.
///
/// `AttributedText` is the package's portable answer to `NSAttributedString` /
/// Foundation's `AttributedString`: a flat list of styled ``Run`` values that
/// carry both inline character attributes (bold, italic, links, …) and the
/// block context of the paragraph they belong to (heading level, list nesting,
/// blockquote depth, …). Because it depends on nothing but the Swift standard
/// library, it behaves identically on every platform — macOS, iOS, Linux and
/// Windows — and can be bridged to `NSAttributedString` where the OS frameworks
/// are available (see `AttributedText+NSAttributedString.swift`).
///
/// The model mirrors `NSAttributedString` conventions: the text is one
/// continuous string in which paragraphs are separated by a `"\n"` terminator,
/// and the terminator carries the paragraph style of the block it ends. Block
/// constructs that can't be expressed as a span of characters — images,
/// horizontal rules and tables — are carried as an ``Attachment`` on a run,
/// with a plain-text fallback in the run's `text` so ``string`` stays readable.
public struct AttributedText: Equatable, Sendable {

	/// The styled runs, in document order.
	public var runs: [Run]

	public init(runs: [Run] = []) {
		self.runs = runs
	}

	/// A contiguous span of text sharing one set of attributes.
	public struct Run: Equatable, Sendable {
		/// The run's characters. For attachment runs this is a plain-text
		/// fallback (image alt text, a rule of dashes, a tab-separated table).
		public var text: String
		/// The character- and paragraph-level attributes applied to `text`.
		public var attributes: Attributes

		public init(_ text: String, _ attributes: Attributes = Attributes()) {
			self.text = text
			self.attributes = attributes
		}
	}
}

// MARK: - Attributes

extension AttributedText {

	/// The full attribute set applied to a ``Run``.
	///
	/// Inline traits (``bold``, ``italic`` …) vary run-to-run within a
	/// paragraph; ``paragraph`` is constant across every run of the same
	/// paragraph, exactly like `NSParagraphStyle` in an `NSAttributedString`.
	public struct Attributes: Equatable, Sendable {
		// MARK: Inline character traits
		public var bold: Bool
		public var italic: Bool
		public var strikethrough: Bool
		/// Monospaced inline / fenced code.
		public var code: Bool
		/// Link destination (also set for autolinks). `nil` when not a link.
		public var link: String?
		/// Super-/subscript positioning. Footnote references are superscript.
		public var baseline: Baseline
		/// When this run is a footnote reference, its assigned number.
		public var footnoteReference: Int?
		/// A non-text payload (image, rule, table) carried by this run.
		public var attachment: Attachment?

		// MARK: Block context
		/// The style of the paragraph this run belongs to.
		public var paragraph: ParagraphStyle

		public init(
			bold: Bool = false,
			italic: Bool = false,
			strikethrough: Bool = false,
			code: Bool = false,
			link: String? = nil,
			baseline: Baseline = .normal,
			footnoteReference: Int? = nil,
			attachment: Attachment? = nil,
			paragraph: ParagraphStyle = ParagraphStyle()
		) {
			self.bold = bold
			self.italic = italic
			self.strikethrough = strikethrough
			self.code = code
			self.link = link
			self.baseline = baseline
			self.footnoteReference = footnoteReference
			self.attachment = attachment
			self.paragraph = paragraph
		}
	}

	/// Vertical positioning of a run relative to the baseline.
	public enum Baseline: Equatable, Sendable {
		case normal
		case superscript
		case `subscript`
	}
}

// MARK: - Paragraph style

extension AttributedText {

	/// The block-level style shared by every run of a paragraph.
	public struct ParagraphStyle: Equatable, Sendable {
		/// What kind of block this paragraph is.
		public var kind: Kind
		/// Horizontal alignment (used by table cells; `.natural` elsewhere).
		public var alignment: Alignment
		/// List membership and nesting, when inside a list item.
		public var list: ListContext?
		/// Blockquote nesting depth (`0` when not quoted).
		public var quoteLevel: Int
		/// The callout this paragraph belongs to, when inside a GitHub/DocC alert.
		public var alert: AlertKind?

		public init(
			kind: Kind = .body,
			alignment: Alignment = .natural,
			list: ListContext? = nil,
			quoteLevel: Int = 0,
			alert: AlertKind? = nil
		) {
			self.kind = kind
			self.alignment = alignment
			self.list = list
			self.quoteLevel = quoteLevel
			self.alert = alert
		}

		/// The kind of block a paragraph represents.
		public enum Kind: Equatable, Sendable {
			/// An ordinary text paragraph.
			case body
			/// An ATX/setext heading, levels 1…6.
			case heading(level: Int)
			/// A fenced or indented code block, with its info-string language.
			case codeBlock(language: String?)
			/// A list item's text line.
			case listItem
			/// A paragraph holding a ``Attachment/table(_:)`` attachment.
			case table
			/// A paragraph holding a ``Attachment/horizontalRule`` attachment.
			case thematicBreak
			/// The bold title line of a GitHub/DocC alert (e.g. "Note").
			case alertTitle
			/// A paragraph in the trailing footnote-definitions block.
			case footnoteDefinition(number: Int)
			/// A raw HTML block, emitted as literal text.
			case htmlBlock
		}
	}

	/// Horizontal text alignment.
	public enum Alignment: Equatable, Sendable {
		case natural
		case left
		case center
		case right
	}
}

// MARK: - Lists

extension AttributedText {

	/// The list context of a list-item paragraph.
	public struct ListContext: Equatable, Sendable {
		/// `true` for ordered (`1.`) lists, `false` for bulleted (`-`) lists.
		public var ordered: Bool
		/// Zero-based nesting depth (`0` is the outermost list).
		public var level: Int
		/// The item's ordinal within its list (1-based; meaningful when ordered).
		public var index: Int
		/// Task-list checkbox state, when the item is a task list item.
		public var checkbox: Checkbox?
		/// The display marker for this item (e.g. `"• "`, `"1. "`, `"☐ "`).
		public var marker: String

		public init(
			ordered: Bool,
			level: Int,
			index: Int,
			checkbox: Checkbox? = nil,
			marker: String
		) {
			self.ordered = ordered
			self.level = level
			self.index = index
			self.checkbox = checkbox
			self.marker = marker
		}
	}

	/// A task-list checkbox state.
	public enum Checkbox: Equatable, Sendable {
		case checked
		case unchecked
	}
}

// MARK: - Attachments

extension AttributedText {

	/// A non-text block carried by a run.
	public enum Attachment: Equatable, Sendable {
		/// An image reference. `alt` is the textual fallback (also the run text).
		case image(source: String, alt: String, title: String?)
		/// A thematic break / horizontal rule.
		case horizontalRule
		/// A table; cells are themselves ``AttributedText`` so inline markup is
		/// preserved.
		case table(Table)
	}

	/// A table attachment: header cells, body rows, and per-column alignment.
	public struct Table: Equatable, Sendable {
		public var headers: [AttributedText]
		public var rows: [[AttributedText]]
		public var alignments: [Alignment]

		public init(
			headers: [AttributedText] = [],
			rows: [[AttributedText]] = [],
			alignments: [Alignment] = []
		) {
			self.headers = headers
			self.rows = rows
			self.alignments = alignments
		}
	}
}

// MARK: - Alerts

extension AttributedText {

	/// A GitHub-/DocC-style callout kind.
	public enum AlertKind: String, Equatable, Sendable, CaseIterable {
		case note
		case tip
		case important
		case warning
		case caution
		case experiment

		/// The human-readable title shown on the callout's first line.
		public var title: String {
			switch self {
			case .note: return "Note"
			case .tip: return "Tip"
			case .important: return "Important"
			case .warning: return "Warning"
			case .caution: return "Caution"
			case .experiment: return "Experiment"
			}
		}

		/// Whether the callout denotes a warning (`alert`) vs informational
		/// (`note`) — mirrors the role attribute the HTML renderer emits.
		public var isWarning: Bool {
			switch self {
			case .warning, .caution: return true
			case .note, .tip, .important, .experiment: return false
			}
		}

		/// Resolves a GitHub `[!TOKEN]` / DocC `Token:` identifier (case-insensitive).
		public init?(token: String) {
			guard let match = AlertKind(rawValue: token.lowercased()) else { return nil }
			self = match
		}
	}
}

// MARK: - Convenience

extension AttributedText {

	/// An attributed text with no runs.
	public static var empty: AttributedText { AttributedText() }

	/// `true` when there are no runs.
	public var isEmpty: Bool { runs.isEmpty }

	/// The concatenated plain-text content of every run, including attachment
	/// fallbacks.
	public var string: String {
		var result = ""
		result.reserveCapacity(runs.reduce(0) { $0 + $1.text.count })
		for run in runs { result += run.text }
		return result
	}

	/// Appends a run.
	public mutating func append(_ run: Run) {
		runs.append(run)
	}

	/// Appends a styled span of text.
	public mutating func append(_ text: String, _ attributes: Attributes = Attributes()) {
		runs.append(Run(text, attributes))
	}

	/// Appends every run of `other`.
	public mutating func append(contentsOf other: AttributedText) {
		runs.append(contentsOf: other.runs)
	}
}
