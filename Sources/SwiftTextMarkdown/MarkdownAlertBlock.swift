import Foundation
import Markdown

/// A GitHub / Obsidian / DocC alert ("callout") recognized in a block quote: the one
/// detector every SwiftText writer shares (HTML, EPUB, PDF, DOCX, Pages and the
/// attributed-string renderer), so an alert means the same thing — and gets the same
/// title and colours — in every output format.
///
/// Recognized forms:
///
/// ```markdown
/// > [!NOTE]
/// > Body text.
///
/// > [!WARNING] Watch out            ← text on the marker line is a custom title (Obsidian)
/// > Body text.
///
/// > [!EXAMPLE]                      ← any single-word kind; unknown kinds use the neutral palette
/// > Body text.
///
/// > Note: Body text.                ← DocC aside; only the known kinds, the rest of the line is body
/// ```
///
/// GitHub renders only its five kinds and ignores text after the marker; Obsidian
/// treats that text as the title and accepts any kind. SwiftText follows Obsidian
/// here, which is a superset: every GitHub alert renders identically.
public struct MarkdownAlertBlock {
	/// Which syntax introduced the alert.
	public enum Syntax: Sendable, Equatable {
		/// `> [!KIND]`, optionally followed by a title on the same line.
		case bracketed
		/// DocC's `> Kind: body` aside.
		case docc
	}

	/// The alert kind, lowercased (`"note"`, `"warning"`, `"example"`, …).
	public var kind: String
	/// The title to display: the custom title when one was given, else the kind's
	/// default title ("Note", "Warning", or the capitalized kind).
	public var title: String
	/// Whether ``title`` was written in the Markdown rather than derived from the kind.
	public var hasCustomTitle: Bool
	public var syntax: Syntax
	/// The alert's content with the marker (and a same-line title) removed, as block
	/// nodes ready to be visited by a renderer.
	public var body: [BlockMarkup]

	/// The colours shared by all writers (HTML/CSS, DOCX, Pages).
	public var palette: MarkdownAlertPalette { MarkdownAlertPalette.palette(forKind: kind) }

	/// The five GitHub kinds plus DocC's `Experiment`, with their default titles.
	public static let knownKinds: [String: String] = [
		"note": "Note", "tip": "Tip", "important": "Important",
		"warning": "Warning", "caution": "Caution", "experiment": "Experiment",
	]

	/// The default title for a kind: its known title, else the kind capitalized
	/// with hyphens and underscores read as spaces (`watch-out` → "Watch out").
	public static func defaultTitle(forKind kind: String) -> String {
		if let known = knownKinds[kind] { return known }
		let words = kind.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
		return words.prefix(1).uppercased() + words.dropFirst()
	}

	/// The Markdown marker line that introduces this alert when written back out:
	/// `[!KIND]`, plus the title when it differs from the kind's default.
	public var markerLine: String {
		Self.markerLine(kind: kind, title: hasCustomTitle ? title : nil)
	}

	/// The marker line for an alert of `kind` with an optional custom `title`: the title
	/// is written only when it differs from the kind's default (`[!WARNING] Watch out`,
	/// but `[!NOTE]` for a note titled "Note"). Readers of other formats use this to
	/// write recovered alerts back as Markdown.
	public static func markerLine(kind: String, title: String?) -> String {
		let marker = "[!\(kind.uppercased())]"
		guard let title, !title.isEmpty, title != defaultTitle(forKind: kind) else { return marker }
		return "\(marker) \(title)"
	}

	/// Recognizes an alert in a block quote, or returns `nil` for an ordinary quote.
	public static func detect(in quote: BlockQuote) -> MarkdownAlertBlock? {
		guard let first = quote.child(at: 0) as? Paragraph,
			  let firstText = first.child(at: 0) as? Text else { return nil }
		let raw = firstText.string
		if raw.hasPrefix("[!"), let closing = raw.firstIndex(of: "]") {
			let token = String(raw[raw.index(raw.startIndex, offsetBy: 2)..<closing])
			guard isValidKind(token) else { return nil }
			var rest = String(raw[raw.index(after: closing)...])
			// Obsidian fold markers (`[!note]-`, `[!note]+`) carry no meaning in a document.
			if rest.hasPrefix("-") || rest.hasPrefix("+") { rest.removeFirst() }
			return bracketed(kind: token.lowercased(), firstLineRest: rest, in: quote)
		}
		if let colon = raw.firstIndex(of: ":") {
			let token = String(raw[..<colon])
			let kind = token.lowercased()
			guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }), knownKinds[kind] != nil else { return nil }
			var rest = String(raw[raw.index(after: colon)...])
			if rest.hasPrefix(" ") { rest.removeFirst() }
			var inlines = Array(first.inlineChildren.dropFirst())
			if !rest.isEmpty { inlines.insert(Text(rest), at: 0) }
			var body = [BlockMarkup]()
			if !inlines.isEmpty { body.append(Paragraph(inlines)) }
			body.append(contentsOf: quote.blockChildren.dropFirst())
			return MarkdownAlertBlock(kind: kind, title: defaultTitle(forKind: kind), hasCustomTitle: false, syntax: .docc, body: body)
		}
		return nil
	}

	/// A kind is a single word: letters, digits, `-` or `_`, starting with a letter.
	public static func isValidKind(_ token: String) -> Bool {
		guard let first = token.first, first.isLetter else { return false }
		return token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
	}

	/// One body block of an alert that a reader recovered from another format.
	public enum RecoveredBlock: Sendable, Equatable {
		/// A paragraph's Markdown; it may span several lines.
		case paragraph(String)
		/// A list item's Markdown with its indentation and marker (`- text`, `  1. text`).
		case listItem(String)
	}

	/// Writes an alert recovered from another format (Pages, DOCX) as a `> [!KIND]`
	/// block, so every reader writes the same Markdown: the marker line (with `title`
	/// when it isn't the kind's default), then the body, with a `>` line between
	/// paragraphs and none between consecutive list items.
	public static func markdown(kind: String, title: String?, body: [RecoveredBlock]) -> String {
		var lines = ["> " + markerLine(kind: kind, title: title)]
		var previousWasItem = false
		for block in body {
			switch block {
			case .listItem(let text):
				if !previousWasItem, lines.count > 1 { lines.append(">") }
				lines.append("> " + text)
				previousWasItem = true
			case .paragraph(let text):
				if lines.count > 1 { lines.append(">") }
				for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
					lines.append(line.isEmpty ? ">" : "> " + line)
				}
				previousWasItem = false
			}
		}
		return lines.joined(separator: "\n")
	}

	private static func bracketed(kind: String, firstLineRest: String, in quote: BlockQuote) -> MarkdownAlertBlock {
		guard let first = quote.child(at: 0) as? Paragraph else {
			return MarkdownAlertBlock(kind: kind, title: defaultTitle(forKind: kind), hasCustomTitle: false, syntax: .bracketed, body: [])
		}
		// The title is the rest of the marker's line: the remaining text of the first
		// inline node, plus any further inlines up to the first line break.
		var titleParts = [firstLineRest]
		var remaining = Array(first.inlineChildren.dropFirst())
		while let next = remaining.first, !(next is SoftBreak), !(next is LineBreak) {
			titleParts.append(next.format().trimmingCharacters(in: .newlines))
			remaining.removeFirst()
		}
		if let next = remaining.first, next is SoftBreak || next is LineBreak { remaining.removeFirst() }
		let title = Self.plainTitle(titleParts.joined())
		var body = [BlockMarkup]()
		if !remaining.isEmpty { body.append(Paragraph(remaining)) }
		body.append(contentsOf: quote.blockChildren.dropFirst())
		return MarkdownAlertBlock(
			kind: kind,
			title: title.isEmpty ? defaultTitle(forKind: kind) : title,
			hasCustomTitle: !title.isEmpty,
			syntax: .bracketed,
			body: body
		)
	}

	/// A title as plain text: Markdown emphasis markers removed, whitespace collapsed.
	private static func plainTitle(_ markdown: String) -> String {
		let stripped = markdown.filter { $0 != "*" && $0 != "_" && $0 != "`" }
		return stripped.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
	}
}

/// The colours of an alert kind, as `RRGGBB` hex strings — the same values as the
/// `.markdown-alert-*` CSS, so DOCX and Pages boxes match the HTML/PDF ones.
public struct MarkdownAlertPalette: Sendable, Equatable {
	/// The box's background tint.
	public var background: String
	/// The left border (and accent) colour.
	public var border: String
	/// The text colour inside the box (title and body).
	public var text: String

	public static let note = MarkdownAlertPalette(background: "DDF4FF", border: "0969DA", text: "0A3069")
	public static let tip = MarkdownAlertPalette(background: "DAFBE1", border: "1A7F37", text: "116329")
	public static let important = MarkdownAlertPalette(background: "FBEFFF", border: "8250DF", text: "5521B5")
	public static let warning = MarkdownAlertPalette(background: "FFF8C5", border: "9A6700", text: "7D4E00")
	public static let caution = MarkdownAlertPalette(background: "FFEBE9", border: "CF222E", text: "A40E26")
	/// Every kind without colours of its own (`experiment`, `example`, custom kinds).
	public static let neutral = MarkdownAlertPalette(background: "F6F8FA", border: "8C959F", text: "424A53")

	public static func palette(forKind kind: String) -> MarkdownAlertPalette {
		switch kind {
		case "note": return .note
		case "tip": return .tip
		case "important": return .important
		case "warning": return .warning
		case "caution": return .caution
		default: return .neutral
		}
	}

	/// A colour as `(red, green, blue)` in 0…1, for writers that want floats (Pages).
	public static func components(_ hex: String) -> (r: Float, g: Float, b: Float) {
		let value = UInt32(hex, radix: 16) ?? 0
		return (Float((value >> 16) & 0xFF) / 255, Float((value >> 8) & 0xFF) / 255, Float(value & 0xFF) / 255)
	}
}

/// The geometry of an alert box, in CSS terms — the one source for every output:
/// the HTML/EPUB/PDF stylesheets are generated from these values (``css``), and the
/// paragraph-based writers (DOCX, Pages) convert the `em` values to points with their
/// body font size, reproducing CSS margin collapsing between the box and its
/// neighbours (see ``collapsedGap(_:_:)``).
public enum MarkdownAlertLayout {
	/// `.markdown-alert { margin: 0.8em 0 }` — the space above and below a box.
	public static let marginEm = 0.8
	/// `.markdown-alert { padding: 0.75em 1em }` — vertical inner padding.
	public static let paddingBlockEm = 0.75
	/// …and horizontal inner padding (from the border to the text).
	public static let paddingInlineEm = 1.0
	/// `.markdown-alert-title { margin: 0 0 0.35em }`.
	public static let titleMarginBottomEm = 0.35
	/// `p { margin: 0.6em 0 }` — paragraphs inside a box; adjacent margins collapse.
	public static let paragraphMarginEm = 0.6
	/// `li { margin: 0.2em 0 }` — between list items inside a box.
	public static let listItemMarginEm = 0.2
	/// `border-left-width: 4px` (a fixed width, as in CSS: 4px = 3pt).
	public static let borderWidthPoints = 3.0
	/// `border-radius: 6px`.
	public static let borderRadiusPx = 6.0
	/// `hr { margin: 1.2em 0 }`.
	public static let ruleMarginEm = 1.2
	/// `body { line-height: 1.6 }` of the default stylesheets.
	public static let bodyLineHeight = 1.6
	/// The half-leading CSS puts above and below every line: (line-height − 1) / 2.
	/// Pages and Word put a line's extra leading below the text instead, so a paragraph
	/// writer adds this to a box's (or rule's) bottom margin to keep the gap to the next
	/// line of text as it looks in CSS.
	public static var halfLeadingEm: Double { (bodyLineHeight - 1) / 2 }

	/// CSS margins between adjacent blocks collapse to the larger of the two.
	public static func collapsedGap(_ a: Double, _ b: Double) -> Double { max(a, b) }

	/// The alert rules of the default HTML/PDF stylesheets: geometry from the
	/// constants above, one colour rule per kind from ``MarkdownAlertPalette``.
	public static var css: String {
		var rules = """
		.markdown-alert {
		    border-left-width: 4px;
		    border-left-style: solid;
		    border-radius: \(fmt(borderRadiusPx))px;
		    margin: \(fmt(marginEm))em 0;
		    padding: \(fmt(paddingBlockEm))em \(fmt(paddingInlineEm))em;
		    background: #\(MarkdownAlertPalette.neutral.background.lowercased());
		    border-left-color: #\(MarkdownAlertPalette.neutral.border.lowercased());
		    color: #\(MarkdownAlertPalette.neutral.text.lowercased());
		    -webkit-print-color-adjust: exact;
		    print-color-adjust: exact;
		}
		.markdown-alert-title {
		    font-weight: 600;
		    margin: 0 0 \(fmt(titleMarginBottomEm))em;
		}
		.markdown-alert > :last-child { margin-bottom: 0; }

		"""
		for kind in ["note", "tip", "important", "warning", "caution"] {
			let palette = MarkdownAlertPalette.palette(forKind: kind)
			rules += ".markdown-alert-\(kind) { background: #\(palette.background.lowercased()); border-left-color: #\(palette.border.lowercased()); color: #\(palette.text.lowercased()); }\n"
		}
		return rules
	}

	/// Rules for the blocks inside a box, for stylesheets whose own paragraph and list
	/// rules differ from the HTML default's. EPUB's book stylesheet, for one, indents
	/// paragraphs and leaves no gap between them; inside a box they are spaced as in
	/// every other output.
	public static var contentCSS: String {
		"""
		.markdown-alert p { margin: \(fmt(paragraphMarginEm))em 0; text-indent: 0; text-align: left; }
		.markdown-alert p.markdown-alert-title { margin: 0 0 \(fmt(titleMarginBottomEm))em; }
		.markdown-alert ul, .markdown-alert ol { margin-top: \(fmt(paragraphMarginEm))em; margin-bottom: \(fmt(paragraphMarginEm))em; }
		.markdown-alert li { margin: \(fmt(listItemMarginEm))em 0; }
		.markdown-alert > :last-child { margin-bottom: 0; }

		"""
	}

	private static func fmt(_ value: Double) -> String {
		value == value.rounded() ? String(Int(value)) : String(value)
	}
}
