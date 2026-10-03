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
	}

	public static func convert(_ markdown: String, options: Options = []) -> String {
		let document = Document(parsing: markdown, options: [.disableSmartOpts])
		return convert(document: document, options: options)
	}

	/// Renders an already-parsed `Document` to the same HTML fragment shape as
	/// ``convert(_:)``. Use this entry point when you need to rewrite the AST
	/// (e.g. with a `MarkupRewriter`) before rendering.
	public static func convert(document: Document, options: Options = []) -> String {
		var renderer = HTMLRenderer(options: options)
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
		let blocks = Array(document.children)
		for (index, block) in blocks.enumerated() {
			if index > 0 { output += "\n" }
			visit(block)
		}
	}

	mutating func visitParagraph(_ paragraph: Paragraph) {
		output += "<p>"
		for child in paragraph.children { visit(child) }
		output += "</p>"
	}

	mutating func visitHeading(_ heading: Heading) {
		let level = max(1, min(heading.level, 6))
		output += "<h\(level)>"
		for child in heading.children { visit(child) }
		output += "</h\(level)>"
	}

	mutating func visitText(_ text: Text) {
		// Body text uses the same escape policy as the legacy parser (only
		// `&<>`). The full `&<>"` policy is reserved for attribute values.
		output += escapeHTMLNotQuote(text.string)
	}

	mutating func visitEmphasis(_ emphasis: Emphasis) {
		output += "<em>"
		for child in emphasis.children { visit(child) }
		output += "</em>"
	}

	mutating func visitStrong(_ strong: Strong) {
		output += "<strong>"
		for child in strong.children { visit(child) }
		output += "</strong>"
	}

	mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
		output += "<del>"
		for child in strikethrough.children { visit(child) }
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
		output += "<a href=\"\(escapeAttribute(href))\">"
		for child in link.children { visit(child) }
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
		output += "<ol>"
		for child in orderedList.children { visit(child) }
		output += "</ol>"
	}

	mutating func visitListItem(_ listItem: ListItem) {
		let isTaskItem: Bool
		switch listItem.checkbox {
		case .checked:
			isTaskItem = true
			// Keep boolean attributes explicit in HTML as well as XHTML. The
			// libxml SAX bridge otherwise omits a final valueless attribute, which
			// would erase the checked state before SwiftTextRender sees the DOM.
			let input = #"<input type="checkbox" disabled="disabled" checked="checked""# + voidClose
			output += #"<li class="task-list-item">"# + input + " "
		case .unchecked:
			isTaskItem = true
			let input = #"<input type="checkbox" disabled="disabled""# + voidClose
			output += #"<li class="task-list-item">"# + input + " "
		case .none:
			isTaskItem = false
			output += "<li>"
		}
		let blocks = Array(listItem.children)
		// Keep a task control and its label in the same inline run even when the
		// item has later blocks, such as a nested list. Single-paragraph list
		// items retain the existing unwrapped `<li>foo</li>` shape as well.
		if let firstParagraph = blocks.first as? Paragraph,
		   isTaskItem || blocks.count == 1 {
			for child in firstParagraph.children { visit(child) }
			for block in blocks.dropFirst() { visit(block) }
		} else {
			for child in blocks { visit(child) }
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

	// MARK: - Tables

	mutating func visitTable(_ table: Table) {
		alignmentStack.append(table.columnAlignments)
		defer { alignmentStack.removeLast() }
		output += "<table>\n"
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
			for inline in cell.children { visit(inline) }
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
	private mutating func emitAlert(_ alert: MarkdownAlertBlock) {
		let role = alert.isWarning ? "alert" : "note"
		output += "<aside class=\"markdown-alert markdown-alert-\(alert.kind)\" data-alert=\"\(alert.kind)\" role=\"\(role)\">"
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
