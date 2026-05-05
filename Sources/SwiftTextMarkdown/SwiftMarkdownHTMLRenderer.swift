import Foundation
import Markdown

/// Markdown -> HTML renderer built on swift-markdown's AST.
///
/// Mirrors the output shape of `SwiftTextHTML.MarkdownToHTML.convert` closely
/// enough that the two implementations can be diffed on the same fixture set
/// during the migration. The hand-rolled parser will be retired once this
/// reaches byte-exact parity (see issue #15).
///
/// Notable behaviors:
/// - `Document.parse` is invoked with `.parseBlockDirectives` disabled so DocC
///   syntax doesn't leak in.
/// - GitHub alert syntax (`> [!NOTE]`) is detected after parsing by inspecting
///   the first inline of each `BlockQuote`, and emitted as the same
///   `<aside class="markdown-alert markdown-alert-note">` shape our hand-rolled
///   parser produces.
/// - Output is the inline HTML fragment — no `<html>`/`<body>` wrapper, and no
///   trailing newlines — which matches `MarkdownToHTML.convert`.
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

	mutating func flush() -> String {
		while output.hasSuffix("\n") { output.removeLast() }
		return output
	}

	mutating func defaultVisit(_ markup: Markup) {
		for child in markup.children { visit(child) }
	}

	mutating func visitDocument(_ document: Document) {
		for child in document.children { visit(child) }
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
		output += escapeHTML(text.string)
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
		output += "<code>" + escapeHTML(inlineCode.code) + "</code>"
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
		let escaped = escapeHTML(code)
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
		// the start of the first paragraph.
		let children = Array(alert.body.children)
		for (index, child) in children.enumerated() {
			if index == 0, let paragraph = child as? Paragraph {
				let inlineChildren = Array(paragraph.children)
				guard !inlineChildren.isEmpty else { continue }
				if let firstText = inlineChildren.first as? Text {
					var stripped = firstText.string
					if let closing = stripped.firstIndex(of: "]") {
						stripped.removeSubrange(stripped.startIndex...closing)
						if stripped.hasPrefix(" ") { stripped.removeFirst() }
					}
					if stripped.isEmpty && inlineChildren.count == 1 { continue }
					output += "<p>"
					if !stripped.isEmpty { output += escapeHTML(stripped) }
					for tail in inlineChildren.dropFirst() { visit(tail) }
					output += "</p>"
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

	private func escapeAttribute(_ string: String) -> String {
		escapeHTML(string)
	}
}
