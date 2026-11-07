import Foundation
import Markdown

/// Markdown -> HTML renderer built on swift-markdown's AST.
///
/// Handles the GFM superset that cmark-gfm exposes — paragraphs, headings,
/// emphasis, links, images, lists (including task lists and nested lists with
/// mixed markers), code, fenced + indented code blocks, tables with column
/// alignment, blockquotes, GitHub/DocC alert callouts, autolinks, setext
/// headings, link reference definitions, and strikethrough.
///
/// This renderer does NOT handle the `[^id]` / `[^id]: …` footnote extension
/// — swift-markdown deliberately doesn't enable it. Footnote support lives in
/// ``MarkdownFootnoteRenderer``, which wraps this renderer.
///
/// Notable behaviors:
/// - GitHub alert syntax (`> [!NOTE]`) is detected after parsing by inspecting
///   the first inline of each `BlockQuote`. swift-markdown's `Aside` node is
///   DocC-style only, so we detect the bracket-bang form ourselves.
/// - cmark-gfm enables smart punctuation by default (typed `--`/`---`/`...`/
///   straight quotes become dashes/ellipsis/curly quotes). We parse with
///   `.disableSmartOpts` so that conversion never happens, matching the
///   legacy parser's policy of literal source fidelity — and, unlike
///   reversing the substitution after the fact, this also leaves any
///   typographic characters already present in the source untouched.
/// - Output is the inline HTML fragment — no `<html>`/`<body>` wrapper.
public enum SwiftMarkdownHTMLRenderer {

	/// Rendering options.
	public struct Options: OptionSet, Sendable {
		public let rawValue: Int
		public init(rawValue: Int) { self.rawValue = rawValue }

		/// Emits raw HTML (inline and block) verbatim instead of escaping it.
		///
		/// GitHub-rendered Markdown — READMEs, release notes, comments —
		/// routinely embeds HTML like `<p align="center"><img …></p>` or
		/// `<details>`. cmark calls this mode "unsafe": only use it when the
		/// output is sanitized or displayed without script execution.
		public static let passThroughRawHTML = Options(rawValue: 1 << 0)

		/// Emits XHTML-serializable markup: void elements are self-closed
		/// (`<hr />`, `<br />`, `<img … />`) and boolean attributes take their
		/// XHTML form (`disabled="disabled"`). Use this when the fragment must be
		/// well-formed XML — e.g. EPUB content documents, which reading systems
		/// parse as XHTML rather than lenient HTML5.
		public static let xhtml = Options(rawValue: 1 << 1)

		/// Gives every heading an `id` — a GitHub-style slug of its text (lowercased,
		/// punctuation dropped, spaces hyphenated, Unicode letters kept, duplicates
		/// suffixed `-1`, `-2`, …) — and honours a trailing `{#custom-id}` attribute,
		/// which is removed from the rendered text.
		public static let headingIDs = Options(rawValue: 1 << 2)

		/// Makes numeric citations clickable. A list item starting with `[n]` gets
		/// `id="citation-n"`, and every other `[n]` (or `[n](#anchor)` / `[[n]](#anchor)`
		/// link) becomes `<a href="#citation-n">[n]</a>` — but only when a matching
		/// reference item exists in the document.
		public static let linkCitations = Options(rawValue: 1 << 3)
	}

	/// The `n` of every list item in `document` that starts with `[n]`.
	public static func citationReferenceNumbers(in document: Document) -> Set<Int> {
		var renderer = HTMLRenderer(options: [.linkCitations])
		renderer.collectReferenceNumbers(in: document)
		return renderer.referenceNumbers
	}

	/// Splits a trailing `{#custom-id}` heading attribute off the heading's plain text.
	public static func splitHeadingID(_ text: String) -> (text: String, id: String?) {
		guard let range = text.range(of: #"\s*\{#([^\s{}<>&"']+)\}$"#, options: .regularExpression) else {
			return (text, nil)
		}
		let attribute = text[range].trimmingCharacters(in: .whitespaces)
		return (String(text[..<range.lowerBound]), String(attribute.dropFirst(2).dropLast()))
	}

	public static func convert(_ markdown: String, options: Options = []) -> String {
		let document = Document(parsing: markdown, options: [.disableSmartOpts])
		return convert(document: document, options: options)
	}

	/// Renders an already-parsed `Document` to the same HTML fragment shape as
	/// ``convert(_:)``. Use this entry point when you need to rewrite the AST
	/// (e.g. with a `MarkupRewriter`) before rendering.
	///
	/// - Parameter citationNumbers: With ``Options/linkCitations``, the reference numbers
	///   to link. Defaults to those found in `document`; pass the set of the whole source
	///   when rendering fragments of it separately.
	public static func convert(document: Document, options: Options = [], citationNumbers: Set<Int>? = nil) -> String {
		var renderer = HTMLRenderer(options: options)
		renderer.referenceNumbers = citationNumbers ?? []
		renderer.hasSharedCitationNumbers = citationNumbers != nil
		renderer.visit(document)
		return renderer.flush()
	}
}

private struct HTMLRenderer: MarkupVisitor {
	typealias Result = Void

	let options: SwiftMarkdownHTMLRenderer.Options

	init(options: SwiftMarkdownHTMLRenderer.Options) {
		self.options = options
	}

	private var output: String = ""
	private var usedHeadingIDs = Set<String>()
	/// Citation numbers that have a `[n]` reference list item (when linking citations).
	fileprivate(set) var referenceNumbers = Set<Int>()
	fileprivate var hasSharedCitationNumbers = false
	private var suppressCitationLinks = false
	private var alignmentStack: [[Table.ColumnAlignment?]] = []

	/// The close for a void element: `" />"` in XHTML mode, `">"` otherwise.
	private var voidClose: String { options.contains(.xhtml) ? " />" : ">" }

	mutating func flush() -> String {
		while output.hasSuffix("\n") { output.removeLast() }
		return output
	}

	mutating func defaultVisit(_ markup: Markup) {
		for child in markup.children { visit(child) }
	}

	mutating func visitDocument(_ document: Document) {
		// Legacy parser joins top-level blocks with "\n". Reproduce that so a
		// multi-block fixture round-trips byte-identically.
		if options.contains(.linkCitations), !hasSharedCitationNumbers {
			collectReferenceNumbers(in: document)
		}
		let blocks = Array(document.children)
		for (index, block) in blocks.enumerated() {
			if index > 0 { output += "\n" }
			visit(block)
		}
	}

	mutating func visitParagraph(_ paragraph: Paragraph) {
		output += "<p>"
		visitInlines(of: paragraph)
		output += "</p>"
	}

	mutating func visitHeading(_ heading: Heading) {
		let level = max(1, min(heading.level, 6))
		guard options.contains(.headingIDs) else {
			output += "<h\(level)>"
			visitInlines(of: heading)
			output += "</h\(level)>"
			return
		}
		let plain = swiftMarkdownPlainText(of: heading).trimmingCharacters(in: .whitespacesAndNewlines)
		var explicitID = SwiftMarkdownHTMLRenderer.splitHeadingID(plain).id
		let attribute = explicitID.map { "{#\($0)}" } ?? ""
		let saved = output
		output = ""
		visitInlines(of: heading)
		var content = output
		output = saved
		if explicitID != nil {
			if let range = content.range(of: attribute, options: [.backwards]),
			   content[range.upperBound...].allSatisfy(\.isWhitespace) {
				content = String(content[..<range.lowerBound])
				while content.last?.isWhitespace == true { content.removeLast() }
			} else {
				explicitID = nil
			}
		}
		let id = explicitID ?? uniqueHeadingID(slug(of: plain))
		if let explicitID { usedHeadingIDs.insert(explicitID) }
		let idAttribute = id.isEmpty ? "" : " id=\"\(escapeAttribute(id))\""
		output += "<h\(level)\(idAttribute)>\(content)</h\(level)>"
	}

	mutating func visitText(_ text: Text) {
		// Body text uses the same escape policy as the legacy parser (only
		// `&<>`). The full `&<>"` policy is reserved for attribute values.
		emitText(text.string)
	}

	mutating func visitEmphasis(_ emphasis: Emphasis) {
		output += "<em>"
		visitInlines(of: emphasis)
		output += "</em>"
	}

	mutating func visitStrong(_ strong: Strong) {
		output += "<strong>"
		visitInlines(of: strong)
		output += "</strong>"
	}

	mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
		output += "<del>"
		visitInlines(of: strikethrough)
		output += "</del>"
	}

	mutating func visitInlineCode(_ inlineCode: InlineCode) {
		// Inline code is not subject to smart-punct (cmark already excludes it)
		// and is escaped without `"` — matches the legacy parser.
		output += "<code>" + escapeHTMLNotQuote(inlineCode.code) + "</code>"
	}

	mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
		if options.contains(.passThroughRawHTML) {
			output += inlineHTML.rawHTML
			return
		}
		// Legacy parser escapes raw HTML markers literally during inlineFormat
		// (the `&<>` substitution runs before regex matching). Match that so an
		// input like `<div>` becomes `&lt;div&gt;` rather than disappearing.
		output += escapeHTMLNotQuote(inlineHTML.rawHTML)
	}

	mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) {
		var raw = htmlBlock.rawHTML
		while raw.hasSuffix("\n") { raw.removeLast() }
		if options.contains(.passThroughRawHTML) {
			output += raw
			return
		}
		// Same policy as inline HTML — escape and emit literal characters.
		output += escapeHTMLNotQuote(raw)
	}

	mutating func visitLink(_ link: Link) {
		let href = link.destination ?? ""
		if let number = citationLinkNumber(for: link) {
			output += "<a href=\"#citation-\(number)\">[\(number)]</a>"
			return
		}
		output += "<a href=\"\(escapeAttribute(href))\">"
		// An anchor can't nest another, so a `[n]` in the label stays plain text.
		let outerSuppression = suppressCitationLinks
		suppressCitationLinks = true
		visitInlines(of: link)
		suppressCitationLinks = outerSuppression
		output += "</a>"
	}

	mutating func visitImage(_ image: Image) {
		let src = image.source ?? ""
		// Walk all descendants so alt text from nested inline formatting
		// (e.g. `![*diagram*](img.png)` or `![link [label]](...)`) is
		// preserved rather than silently dropped.
		let alt = swiftMarkdownPlainText(of: image)
		output += "<img src=\"\(escapeAttribute(src))\" alt=\"\(escapeAttribute(alt))\"\(voidClose)"
	}

	mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
		var code = codeBlock.code
		if code.hasSuffix("\n") { code.removeLast() }
		// Code blocks escape only `&<>` (not `"`) — matches the legacy parser's
		// simpler escape policy. Smart-punct is also irrelevant inside code.
		let escaped = escapeHTMLNotQuote(code)
		if let language = codeBlock.language, !language.isEmpty {
			output += "<pre><code class=\"language-\(escapeAttribute(language))\">\(escaped)</code></pre>"
		} else {
			output += "<pre><code>\(escaped)</code></pre>"
		}
	}

	mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
		output += "<hr\(voidClose)"
	}

	mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
		output += "<ul>"
		for child in unorderedList.children { visit(child) }
		output += "</ul>"
	}

	mutating func visitOrderedList(_ orderedList: OrderedList) {
		// Like the CommonMark reference renderer, only a non-1 start is written.
		output += orderedList.startIndex == 1 ? "<ol>" : "<ol start=\"\(orderedList.startIndex)\">"
		for child in orderedList.children { visit(child) }
		output += "</ol>"
	}

	mutating func visitListItem(_ listItem: ListItem) {
		let isTaskItem: Bool
		let referenceNumber = options.contains(.linkCitations) ? Self.referenceNumber(of: listItem) : nil
		let idAttribute = referenceNumber.map { " id=\"citation-\($0)\"" } ?? ""
		switch listItem.checkbox {
		case .checked:
			isTaskItem = true
			// Keep boolean attributes explicit in HTML as well as XHTML. The
			// libxml SAX bridge otherwise omits a final valueless attribute, which
			// would erase the checked state before SwiftTextRender sees the DOM.
			let input = #"<input type="checkbox" disabled="disabled" checked="checked""# + voidClose
			output += #"<li class="task-list-item""# + idAttribute + ">" + input + " "
		case .unchecked:
			isTaskItem = true
			let input = #"<input type="checkbox" disabled="disabled""# + voidClose
			output += #"<li class="task-list-item""# + idAttribute + ">" + input + " "
		case .none:
			isTaskItem = false
			output += "<li\(idAttribute)>"
		}
		let blocks = Array(listItem.children)
		// Keep a task control and its label in the same inline run even when the
		// item has later blocks, such as a nested list. Single-paragraph list
		// items retain the existing unwrapped `<li>foo</li>` shape as well.
		if let firstParagraph = blocks.first as? Paragraph,
		   isTaskItem || blocks.count == 1 {
			suppressCitationLinks = referenceNumber != nil
			visitInlines(of: firstParagraph)
			suppressCitationLinks = false
			for block in blocks.dropFirst() { visit(block) }
		} else {
			for (index, child) in blocks.enumerated() {
				suppressCitationLinks = index == 0 && referenceNumber != nil
				visit(child)
				suppressCitationLinks = false
			}
		}
		output += "</li>"
	}

	mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
		if let alert = MarkdownAlertBlock.detect(in: blockQuote) {
			emitAlert(alert)
			return
		}
		output += "<blockquote>"
		for child in blockQuote.children { visit(child) }
		output += "</blockquote>"
	}

	mutating func visitSoftBreak(_ softBreak: SoftBreak) {
		output += "\n"
	}

	mutating func visitLineBreak(_ lineBreak: LineBreak) {
		output += "<br\(voidClose)"
	}

	// MARK: - Inlines, headings and citations

	/// Visits the inline children of `parent`, merging adjacent `Text` nodes first —
	/// cmark splits an unresolved `[1]` into `[`, `1`, `]` — so citations can be
	/// recognised across them.
	private mutating func visitInlines(of parent: Markup) {
		var pending = ""
		var hasPending = false
		for child in parent.children {
			if let text = child as? Text {
				pending += text.string
				hasPending = true
				continue
			}
			if hasPending { emitText(pending); pending = ""; hasPending = false }
			visit(child)
		}
		if hasPending { emitText(pending) }
	}

	private mutating func emitText(_ string: String) {
		guard options.contains(.linkCitations), !suppressCitationLinks, !referenceNumbers.isEmpty,
		      string.contains("[") else {
			output += escapeHTMLNotQuote(string)
			return
		}
		var rest = Substring(string)
		while let open = rest.firstIndex(of: "[") {
			output += escapeHTMLNotQuote(String(rest[..<open]))
			let afterOpen = rest.index(after: open)
			let digits = rest[afterOpen...].prefix(while: \.isASCII).prefix(while: \.isNumber)
			let close = rest.index(afterOpen, offsetBy: digits.count)
			if !digits.isEmpty, close < rest.endIndex, rest[close] == "]",
			   let number = Int(digits), referenceNumbers.contains(number) {
				output += "<a href=\"#citation-\(number)\">[\(number)]</a>"
				rest = rest[rest.index(after: close)...]
			} else {
				output += "["
				rest = rest[afterOpen...]
			}
		}
		output += escapeHTMLNotQuote(String(rest))
	}

	/// The citation number of a `[n](#anchor)` / `[[n]](#anchor)` link, if it has a reference item.
	private func citationLinkNumber(for link: Link) -> Int? {
		guard options.contains(.linkCitations), !suppressCitationLinks,
		      link.destination?.hasPrefix("#") == true else { return nil }
		var label = swiftMarkdownPlainText(of: link).trimmingCharacters(in: .whitespaces)
		if label.hasPrefix("["), label.hasSuffix("]") { label = String(label.dropFirst().dropLast()) }
		guard !label.isEmpty, label.allSatisfy({ $0.isASCII && $0.isNumber }),
		      let number = Int(label), referenceNumbers.contains(number) else { return nil }
		return number
	}

	/// The `n` of a list item whose text starts with `[n]` (ignoring leading empty anchors).
	private static func referenceNumber(of listItem: ListItem) -> Int? {
		guard let paragraph = listItem.children.first(where: { $0 is Paragraph }) as? Paragraph else { return nil }
		var prefix = ""
		for child in paragraph.children {
			if child is InlineHTML { continue }
			guard let text = child as? Text else { break }
			prefix += text.string
			if prefix.count > 12 { break }
		}
		guard prefix.hasPrefix("[") else { return nil }
		let digits = prefix.dropFirst().prefix(while: { $0.isASCII && $0.isNumber })
		let tail = prefix.dropFirst(1 + digits.count)
		guard !digits.isEmpty, tail.hasPrefix("]") else { return nil }
		return Int(digits)
	}

	mutating func collectReferenceNumbers(in markup: Markup) {
		if let item = markup as? ListItem, let number = Self.referenceNumber(of: item) {
			referenceNumbers.insert(number)
		}
		for child in markup.children { collectReferenceNumbers(in: child) }
	}

	/// A GitHub-style slug: lowercased, letters/digits/`-`/`_` kept, spaces hyphenated.
	private func slug(of text: String) -> String {
		var result = ""
		for character in text.lowercased() {
			if character == " " || character == "-" {
				result.append("-")
			} else if character == "_" || character.isLetter || character.isNumber {
				result.append(character)
			}
		}
		return result
	}

	private mutating func uniqueHeadingID(_ base: String) -> String {
		guard !base.isEmpty else { return "" }
		var candidate = base
		var counter = 0
		while usedHeadingIDs.contains(candidate) {
			counter += 1
			candidate = "\(base)-\(counter)"
		}
		usedHeadingIDs.insert(candidate)
		return candidate
	}

	// MARK: - Tables

	private static let wideTableColumnCount = 8

	mutating func visitTable(_ table: Table) {
		alignmentStack.append(table.columnAlignments)
		defer { alignmentStack.removeLast() }
		// Marked here so the print CSS can constrain wide tables without `:has()`,
		// which WebKit only supports from 15.4 (iOS 15.0–15.3 are still deployment targets).
		let wide = table.columnAlignments.count >= Self.wideTableColumnCount
		output += wide ? "<table class=\"wide-table\">\n" : "<table>\n"
		visit(table.head)
		output += "\n"
		visit(table.body)
		output += "</table>"
	}

	mutating func visitTableHead(_ tableHead: Table.Head) {
		output += "<thead><tr>"
		emitCells(tableHead, tag: "th")
		output += "</tr></thead>"
	}

	mutating func visitTableBody(_ tableBody: Table.Body) {
		output += "<tbody>\n"
		let rows = Array(tableBody.children)
		for row in rows {
			if let row = row as? Table.Row {
				output += "<tr>"
				emitCells(row, tag: "td")
				output += "</tr>\n"
			}
		}
		output += "</tbody>"
	}

	private mutating func emitCells(_ container: Markup, tag: String) {
		let alignments = alignmentStack.last ?? []
		var index = 0
		for child in container.children {
			guard let cell = child as? Table.Cell else { continue }
			let style = cellStyle(for: index, alignments: alignments)
			output += "<\(tag)\(style)>"
			visitInlines(of: cell)
			output += "</\(tag)>"
			index += 1
		}
	}

	private func cellStyle(for index: Int, alignments: [Table.ColumnAlignment?]) -> String {
		guard index < alignments.count, let alignment = alignments[index] else { return "" }
		switch alignment {
		case .left: return ""
		case .center: return " style=\"text-align: center;\""
		case .right: return " style=\"text-align: right;\""
		}
	}

	// MARK: - Alerts (GitHub / Obsidian / DocC)

	/// An alert as `<aside class="markdown-alert markdown-alert-KIND">` with a title
	/// paragraph, the shape GitHub emits (as a `div`), styled by `.markdown-alert-*` CSS.
	/// Detection and titles come from ``MarkdownAlertBlock``, shared by every writer.
	/// Every kind is `role="note"`: ARIA's `alert` is a live region for time-sensitive
	/// messages, and it isn't allowed on `aside` at all (epubcheck rejects it). The
	/// title says what kind of note it is.
	private mutating func emitAlert(_ alert: MarkdownAlertBlock) {
		output += "<aside class=\"markdown-alert markdown-alert-\(alert.kind)\" data-alert=\"\(alert.kind)\" role=\"note\">"
		output += "<p class=\"markdown-alert-title\">\(escapeHTMLNotQuote(alert.title))</p>"
		for child in alert.body { visit(child) }
		output += "</aside>"
	}

	// MARK: - Escaping

	/// Escapes `&<>"` — used for attribute values where the surrounding double
	/// quote marks must be preserved.
	private func escapeHTML(_ string: String) -> String {
		var result = ""
		result.reserveCapacity(string.count)
		for character in string {
			switch character {
			case "&": result += "&amp;"
			case "<": result += "&lt;"
			case ">": result += "&gt;"
			case "\"": result += "&quot;"
			default: result.append(character)
			}
		}
		return result
	}

	/// Escapes `&<>` only — matches the legacy parser's policy for code blocks
	/// and inline raw HTML, where `"` is left literal.
	private func escapeHTMLNotQuote(_ string: String) -> String {
		var result = ""
		result.reserveCapacity(string.count)
		for character in string {
			switch character {
			case "&": result += "&amp;"
			case "<": result += "&lt;"
			case ">": result += "&gt;"
			default: result.append(character)
			}
		}
		return result
	}

	private func escapeAttribute(_ string: String) -> String {
		escapeHTML(string)
	}

}
