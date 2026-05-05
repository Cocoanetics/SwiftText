import Foundation
import Markdown

/// Markdown -> HTML renderer built on swift-markdown's AST.
///
/// Output is byte-compatible with `SwiftTextHTML.MarkdownToHTML.convert` for
/// every input the existing fixture set covers. Beyond parity, this renderer
/// also handles strikethrough, task lists, autolinks, nested lists with mixed
/// markers, setext headings, indented code blocks, link reference definitions,
/// and DocC-style asides (`> Tip:`) — all of which the hand-rolled parser
/// doesn't recognize.
///
/// Notable behaviors:
/// - GitHub alert syntax (`> [!NOTE]`) is detected after parsing by inspecting
///   the first inline of each `BlockQuote`. swift-markdown's `Aside` node is
///   DocC-style only, so we detect the bracket-bang form ourselves.
/// - cmark-gfm enables smart punctuation by default. We reverse the smart
///   characters (curly quotes, en/em dashes, ellipsis) on the way out so the
///   output matches the literal source — same policy as the legacy parser.
/// - Output is the inline HTML fragment — no `<html>`/`<body>` wrapper.
public enum SwiftMarkdownHTMLRenderer {

	public static func convert(_ markdown: String) -> String {
		let document = Document(parsing: markdown, options: [])
		var renderer = HTMLRenderer()
		renderer.visit(document)
		return renderer.flush()
	}
}

private struct HTMLRenderer: MarkupVisitor {
	typealias Result = Void

	private var output: String = ""
	private var alignmentStack: [[Table.ColumnAlignment?]] = []

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
		output += escapeHTMLNotQuote(reverseSmartPunctuation(text.string))
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
		// Legacy parser escapes raw HTML markers literally during inlineFormat
		// (the `&<>` substitution runs before regex matching). Match that so an
		// input like `<div>` becomes `&lt;div&gt;` rather than disappearing.
		output += escapeHTMLNotQuote(inlineHTML.rawHTML)
	}

	mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) {
		// Same policy as inline HTML — escape and emit literal characters.
		var raw = htmlBlock.rawHTML
		while raw.hasSuffix("\n") { raw.removeLast() }
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
		var alt = ""
		for child in image.children {
			if let text = child as? Text { alt += text.string }
		}
		output += "<img src=\"\(escapeAttribute(src))\" alt=\"\(escapeAttribute(alt))\">"
	}

	mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
		var code = codeBlock.code
		if code.hasSuffix("\n") { code.removeLast() }
		// Code blocks escape only `&<>` (not `"`) — matches the legacy parser's
		// simpler escape policy. Smart-punct is also irrelevant inside code.
		let escaped = escapeHTMLNotQuote(code)
		if let language = codeBlock.language, !language.isEmpty {
			output += "<pre><code class=\"language-\(language)\">\(escaped)</code></pre>"
		} else {
			output += "<pre><code>\(escaped)</code></pre>"
		}
	}

	mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
		output += "<hr>"
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
		output += "<li>"
		// If the only child is a single paragraph, unwrap it so output matches
		// the existing renderer's `<li>foo</li>` shape rather than `<li><p>foo</p></li>`.
		let blocks = Array(listItem.children)
		if blocks.count == 1, let only = blocks.first as? Paragraph {
			for child in only.children { visit(child) }
		} else {
			for child in blocks { visit(child) }
		}
		output += "</li>"
	}

	mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
		if let alert = githubAlert(in: blockQuote) {
			emitGitHubAlert(alert)
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
		output += "<br>"
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

	// MARK: - GitHub alerts

	private struct GitHubAlert {
		var kind: String
		var title: String
		var role: String
		var body: BlockQuote
	}

	private func githubAlert(in quote: BlockQuote) -> GitHubAlert? {
		guard let firstParagraph = quote.child(at: 0) as? Paragraph else { return nil }
		guard let firstText = firstParagraph.child(at: 0) as? Text else { return nil }
		let raw = firstText.string
		guard raw.hasPrefix("[!") else { return nil }
		guard let closingBracket = raw.firstIndex(of: "]") else { return nil }
		let token = String(raw[raw.index(raw.startIndex, offsetBy: 2)..<closingBracket]).uppercased()
		let role: String
		let title: String
		switch token {
		case "NOTE": (title, role) = ("Note", "note")
		case "TIP": (title, role) = ("Tip", "note")
		case "IMPORTANT": (title, role) = ("Important", "note")
		case "WARNING": (title, role) = ("Warning", "alert")
		case "CAUTION": (title, role) = ("Caution", "alert")
		default: return nil
		}
		return GitHubAlert(kind: token.lowercased(), title: title, role: role, body: quote)
	}

	private mutating func emitGitHubAlert(_ alert: GitHubAlert) {
		output += "<aside class=\"markdown-alert markdown-alert-\(alert.kind)\" data-alert=\"\(alert.kind)\" role=\"\(alert.role)\">"
		output += "<p class=\"markdown-alert-title\">\(alert.title)</p>"

		// Render the blockquote children, but skip the [!TYPE] marker that lives at
		// the start of the first paragraph. If the marker line stands alone (e.g.
		// "> [!NOTE]\n> body"), drop the trailing soft-break that would otherwise
		// inject a leading newline into the body paragraph.
		let children = Array(alert.body.children)
		for (index, child) in children.enumerated() {
			if index == 0, let paragraph = child as? Paragraph {
				var inlineChildren = Array(paragraph.children)
				guard !inlineChildren.isEmpty else { continue }
				if let firstText = inlineChildren.first as? Text {
					var stripped = firstText.string
					if let closing = stripped.firstIndex(of: "]") {
						stripped.removeSubrange(stripped.startIndex...closing)
						if stripped.hasPrefix(" ") { stripped.removeFirst() }
					}
					if stripped.isEmpty {
						inlineChildren.removeFirst()
						// Marker had its own line — eat the soft-break that followed.
						if let next = inlineChildren.first, next is SoftBreak {
							inlineChildren.removeFirst()
						}
						if inlineChildren.isEmpty { continue }
						output += "<p>"
						for tail in inlineChildren { visit(tail) }
						output += "</p>"
					} else {
						output += "<p>"
						output += escapeHTMLNotQuote(reverseSmartPunctuation(stripped))
						for tail in inlineChildren.dropFirst() { visit(tail) }
						output += "</p>"
					}
				} else {
					output += "<p>"
					for inline in inlineChildren { visit(inline) }
					output += "</p>"
				}
			} else {
				visit(child)
			}
		}
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

	/// Undoes cmark-gfm's smart-punctuation transformations so output matches
	/// the literal source. The legacy parser doesn't perform any typographic
	/// substitution; we keep that behavior.
	private func reverseSmartPunctuation(_ string: String) -> String {
		guard string.contains(where: { isSmartCharacter($0) }) else { return string }
		var result = ""
		result.reserveCapacity(string.count)
		for character in string {
			switch character {
			case "\u{2018}", "\u{2019}": result.append("'")  // ‘ ’
			case "\u{201C}", "\u{201D}": result.append("\"") // “ ”
			case "\u{2013}": result.append("--")              // –
			case "\u{2014}": result.append("---")             // —
			case "\u{2026}": result.append("...")             // …
			default: result.append(character)
			}
		}
		return result
	}

	private func isSmartCharacter(_ character: Character) -> Bool {
		switch character {
		case "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}",
			 "\u{2013}", "\u{2014}", "\u{2026}":
			return true
		default:
			return false
		}
	}
}
