import Foundation
import Markdown
import SwiftTextMarkdown

/// Markdown → ``AttributedText`` renderer built on swift-markdown's AST.
///
/// This is the attributed-text counterpart to ``SwiftMarkdownHTMLRenderer``: it
/// covers the same GFM superset — paragraphs, ATX/setext headings, emphasis,
/// strong, strikethrough, inline + fenced/indented code, links, autolinks,
/// images, ordered/unordered/nested/task lists, tables with column alignment,
/// blockquotes, GitHub `[!NOTE]` / DocC `Note:` alerts, thematic breaks, raw
/// HTML and the `[^id]` footnote extension (via ``MarkdownFootnoteParser``,
/// exactly as the HTML renderer and DOCX writer do).
///
/// The output is a flat, platform-independent ``AttributedText``. Paragraphs are
/// separated by a `"\n"` terminator that carries the ending paragraph's style,
/// matching `NSAttributedString` conventions, so the result bridges cleanly to
/// `NSAttributedString` where the OS frameworks exist.
///
/// Like the HTML renderer, cmark-gfm's smart-punctuation substitutions (curly
/// quotes, en/em dashes, ellipsis) are reversed to the literal source by
/// default; pass ``Options/preserveSmartPunctuation`` to keep them.
public enum MarkdownAttributedTextRenderer {

	/// Rendering options.
	public struct Options: OptionSet, Sendable {
		public let rawValue: Int
		public init(rawValue: Int) { self.rawValue = rawValue }

		/// Keep cmark-gfm's smart typographic characters instead of reversing
		/// them to their literal source spelling (`"`, `'`, `--`, `---`, `...`).
		public static let preserveSmartPunctuation = Options(rawValue: 1 << 0)
	}

	/// Converts Markdown to ``AttributedText``, expanding `[^id]` footnote
	/// references and appending a definitions block for `[^id]: …` definitions.
	public static func convert(_ markdown: String, options: Options = []) -> AttributedText {
		let (cleaned, definitions) = MarkdownFootnoteParser.extractDefinitions(from: markdown)

		// Fast path: no footnote definitions -> nothing to resolve.
		guard !definitions.isEmpty else {
			var builder = Builder(options: options, resolver: nil)
			builder.emitBlocks(Document(parsing: cleaned, options: []).children, BlockContext())
			return AttributedText(runs: trimTrailingTerminator(builder.runs))
		}

		let resolver = MarkdownFootnoteResolver(definitionIDs: definitions.map(\.id))

		// Body: walking in document order assigns footnote numbers in source order.
		var builder = Builder(options: options, resolver: resolver)
		builder.emitBlocks(Document(parsing: cleaned, options: []).children, BlockContext())
		var runs = builder.runs

		// Render each referenced definition. A definition can be referenced only
		// from inside another that appears earlier in source, so re-scan until a
		// pass renders nothing new (same loop as the HTML/DOCX paths).
		var runsByNumber: [Int: [AttributedText.Run]] = [:]
		var renderedIDs = Set<String>()
		var renderedNew = true
		while renderedNew {
			renderedNew = false
			for definition in definitions where !renderedIDs.contains(definition.id) {
				guard let number = resolver.number(forID: definition.id) else { continue }
				runsByNumber[number] = renderFootnoteDefinition(
					definition.body, number: number, options: options, resolver: resolver
				)
				renderedIDs.insert(definition.id)
				renderedNew = true
			}
		}

		for (_, defRuns) in runsByNumber.sorted(by: { $0.key < $1.key }) {
			runs.append(contentsOf: defRuns)
		}

		return AttributedText(runs: trimTrailingTerminator(runs))
	}

	/// Renders an already-parsed `Document` (no footnote extraction — use
	/// ``convert(_:options:)`` for that). Mirrors
	/// ``SwiftMarkdownHTMLRenderer/convert(document:options:)``.
	public static func convert(document: Document, options: Options = []) -> AttributedText {
		var builder = Builder(options: options, resolver: nil)
		builder.emitBlocks(document.children, BlockContext())
		return AttributedText(runs: trimTrailingTerminator(builder.runs))
	}

	// MARK: Footnote definitions

	/// Renders one `[^id]: …` definition body into runs prefixed with a bold
	/// `"N. "` label, with every body paragraph marked as a footnote definition.
	private static func renderFootnoteDefinition(
		_ body: String, number: Int, options: Options, resolver: MarkdownFootnoteResolver
	) -> [AttributedText.Run] {
		var builder = Builder(options: options, resolver: resolver)
		builder.emitBlocks(Document(parsing: body, options: []).children, BlockContext())
		var runs = builder.runs

		// Re-tag plain body paragraphs as footnote definitions so consumers can
		// style the trailing block distinctly.
		for index in runs.indices where runs[index].attributes.paragraph.kind == .body {
			runs[index].attributes.paragraph.kind = .footnoteDefinition(number: number)
		}

		let labelStyle = AttributedText.ParagraphStyle(kind: .footnoteDefinition(number: number))
		let label = AttributedText.Run(
			"\(number). ",
			AttributedText.Attributes(bold: true, paragraph: runs.first?.attributes.paragraph ?? labelStyle)
		)
		if runs.isEmpty {
			return [label, AttributedText.Run("\n", AttributedText.Attributes(paragraph: labelStyle))]
		}
		runs.insert(label, at: 0)
		return runs
	}
}

// MARK: - Trailing terminator trimming

/// Drops the single paragraph terminator that ends the last paragraph, so the
/// attributed text doesn't end on a stray newline.
private func trimTrailingTerminator(_ runs: [AttributedText.Run]) -> [AttributedText.Run] {
	guard let last = runs.last else { return runs }
	if last.text == "\n", last.attributes.attachment == nil {
		return Array(runs.dropLast())
	}
	return runs
}

// MARK: - Block context

/// The nesting context carried down the block tree while rendering.
private struct BlockContext {
	/// Blockquote nesting depth.
	var quoteLevel: Int = 0
	/// Zero-based list nesting depth (for the *next* list encountered).
	var listDepth: Int = 0
	/// The alert this subtree belongs to, when inside a GitHub/DocC callout.
	var alert: AttributedText.AlertKind? = nil
}

/// The inline character style accumulated while descending inline nodes.
private struct InlineStyle {
	var bold = false
	var italic = false
	var strikethrough = false
	var code = false
	var link: String? = nil
	var baseline: AttributedText.Baseline = .normal
}

// MARK: - Builder

private struct Builder {
	let options: Options
	let resolver: MarkdownFootnoteResolver?
	var runs: [AttributedText.Run] = []

	typealias Options = MarkdownAttributedTextRenderer.Options

	private var preserveSmartPunctuation: Bool {
		options.contains(.preserveSmartPunctuation)
	}

	// MARK: Block emission

	mutating func emitBlocks(_ children: some Sequence<Markup>, _ context: BlockContext) {
		for child in children { emitBlock(child, context) }
	}

	mutating func emitBlock(_ markup: Markup, _ context: BlockContext) {
		switch markup {
		case let paragraph as Paragraph:
			emitParagraphLike(Array(paragraph.children), paragraphStyle(.body, context))
		case let heading as Heading:
			let level = max(1, min(heading.level, 6))
			emitParagraphLike(Array(heading.children), paragraphStyle(.heading(level: level), context))
		case let codeBlock as CodeBlock:
			emitCodeBlock(codeBlock, context)
		case let htmlBlock as HTMLBlock:
			emitHTMLBlock(htmlBlock, context)
		case is ThematicBreak:
			emitAttachmentParagraph(.horizontalRule, fallback: "", kind: .thematicBreak, context)
		case let blockQuote as BlockQuote:
			emitBlockQuote(blockQuote, context)
		case let unordered as UnorderedList:
			emitList(unordered, ordered: false, context)
		case let ordered as OrderedList:
			emitList(ordered, ordered: true, context)
		case let table as Table:
			emitTable(table, context)
		default:
			// Unknown container: descend so nested leaf blocks still render.
			emitBlocks(markup.children, context)
		}
	}

	/// Emits inline content as one paragraph, terminated by a styled newline.
	private mutating func emitParagraphLike(_ inlines: [Markup], _ style: AttributedText.ParagraphStyle) {
		runs.append(contentsOf: collectInlineRuns(inlines, style))
		endParagraph(style)
	}

	/// Appends the paragraph terminator carrying `style`.
	private mutating func endParagraph(_ style: AttributedText.ParagraphStyle) {
		runs.append(AttributedText.Run("\n", AttributedText.Attributes(paragraph: style)))
	}

	private func paragraphStyle(
		_ kind: AttributedText.ParagraphStyle.Kind, _ context: BlockContext
	) -> AttributedText.ParagraphStyle {
		AttributedText.ParagraphStyle(kind: kind, quoteLevel: context.quoteLevel, alert: context.alert)
	}

	// MARK: Leaf blocks

	private mutating func emitCodeBlock(_ codeBlock: CodeBlock, _ context: BlockContext) {
		var code = codeBlock.code
		if code.hasSuffix("\n") { code.removeLast() }
		let style = paragraphStyle(.codeBlock(language: codeBlock.language), context)
		runs.append(AttributedText.Run(code, AttributedText.Attributes(code: true, paragraph: style)))
		endParagraph(style)
	}

	private mutating func emitHTMLBlock(_ htmlBlock: HTMLBlock, _ context: BlockContext) {
		var raw = htmlBlock.rawHTML
		while raw.hasSuffix("\n") { raw.removeLast() }
		let style = paragraphStyle(.htmlBlock, context)
		runs.append(AttributedText.Run(raw, AttributedText.Attributes(paragraph: style)))
		endParagraph(style)
	}

	private mutating func emitAttachmentParagraph(
		_ attachment: AttributedText.Attachment,
		fallback: String,
		kind: AttributedText.ParagraphStyle.Kind,
		_ context: BlockContext
	) {
		let style = paragraphStyle(kind, context)
		runs.append(AttributedText.Run(fallback, AttributedText.Attributes(attachment: attachment, paragraph: style)))
		endParagraph(style)
	}

	// MARK: Blockquotes & alerts

	private mutating func emitBlockQuote(_ blockQuote: BlockQuote, _ context: BlockContext) {
		if let detected = detectAlert(in: blockQuote) {
			emitAlert(blockQuote, kind: detected.kind, terminator: detected.terminator, context)
			return
		}
		var inner = context
		inner.quoteLevel += 1
		emitBlocks(blockQuote.children, inner)
	}

	private mutating func emitAlert(
		_ blockQuote: BlockQuote,
		kind: AttributedText.AlertKind,
		terminator: Character,
		_ context: BlockContext
	) {
		// Title line: a bold label carrying the alert kind.
		let titleStyle = AttributedText.ParagraphStyle(
			kind: .alertTitle, quoteLevel: context.quoteLevel, alert: kind
		)
		runs.append(AttributedText.Run(kind.title, AttributedText.Attributes(bold: true, paragraph: titleStyle)))
		endParagraph(titleStyle)

		var bodyContext = context
		bodyContext.alert = kind

		let children = Array(blockQuote.children)
		for (index, child) in children.enumerated() {
			if index == 0, let paragraph = child as? Paragraph {
				let inlines = strippedAlertMarker(in: paragraph, terminator: terminator)
				if !inlines.isEmpty {
					emitParagraphLike(inlines, paragraphStyle(.body, bodyContext))
				}
			} else {
				emitBlock(child, bodyContext)
			}
		}
	}

	/// Removes the leading `[!TYPE]` / `Token:` marker from an alert's first
	/// paragraph, returning the remaining inline nodes. Mirrors the HTML
	/// renderer's `emitGitHubAlert` surgery.
	private func strippedAlertMarker(in paragraph: Paragraph, terminator: Character) -> [Markup] {
		var inlines = Array(paragraph.children)
		guard let firstText = inlines.first as? Text else { return inlines }

		var stripped = firstText.string
		if let closing = stripped.firstIndex(of: terminator) {
			stripped.removeSubrange(stripped.startIndex...closing)
			if stripped.hasPrefix(" ") { stripped.removeFirst() }
		}

		if stripped.isEmpty {
			inlines.removeFirst()
			// Marker stood on its own line — drop the soft break that followed.
			if let next = inlines.first, next is SoftBreak {
				inlines.removeFirst()
			}
		} else {
			inlines[0] = Text(stripped)
		}
		return inlines
	}

	// MARK: Lists

	private mutating func emitList(_ list: ListItemContainer, ordered: Bool, _ context: BlockContext) {
		let level = context.listDepth
		var index = ordered ? orderedListStart(list) : 1
		for case let item as ListItem in list.children {
			emitListItem(item, ordered: ordered, level: level, index: index, context: context)
			index += 1
		}
	}

	private mutating func emitListItem(
		_ item: ListItem, ordered: Bool, level: Int, index: Int, context: BlockContext
	) {
		let checkbox: AttributedText.Checkbox?
		switch item.checkbox {
		case .checked: checkbox = .checked
		case .unchecked: checkbox = .unchecked
		case .none: checkbox = nil
		}

		let marker = listMarker(ordered: ordered, index: index, checkbox: checkbox)
		let leadContext = AttributedText.ListContext(
			ordered: ordered, level: level, index: index, checkbox: checkbox, marker: marker
		)
		let leadStyle = AttributedText.ParagraphStyle(
			kind: .listItem, list: leadContext, quoteLevel: context.quoteLevel, alert: context.alert
		)

		var emittedLead = false
		var nested = context
		nested.listDepth = level + 1

		for child in item.children {
			switch child {
			case let paragraph as Paragraph:
				if emittedLead {
					// Continuation paragraph of a loose item: same indentation,
					// no repeated marker.
					var continuation = leadStyle
					continuation.list?.marker = ""
					emitParagraphLike(Array(paragraph.children), continuation)
				} else {
					emitParagraphLike(Array(paragraph.children), leadStyle)
					emittedLead = true
				}
			case let unordered as UnorderedList:
				emitList(unordered, ordered: false, nested)
			case let ordered as OrderedList:
				emitList(ordered, ordered: true, nested)
			default:
				emitBlock(child, context)
			}
		}
	}

	private func listMarker(ordered: Bool, index: Int, checkbox: AttributedText.Checkbox?) -> String {
		if let checkbox {
			return checkbox == .checked ? "\u{2611} " : "\u{2610} "  // ☑ / ☐
		}
		return ordered ? "\(index). " : "\u{2022} "  // •
	}

	private func orderedListStart(_ list: ListItemContainer) -> Int {
		guard let ordered = list as? OrderedList else { return 1 }
		return Int(ordered.startIndex)
	}

	// MARK: Tables

	private mutating func emitTable(_ table: Table, _ context: BlockContext) {
		let alignments: [AttributedText.Alignment] = table.columnAlignments.map { alignment in
			switch alignment {
			case .left: return .left
			case .center: return .center
			case .right: return .right
			case .none: return .natural
			}
		}

		func cell(_ markup: Markup, column: Int) -> AttributedText {
			let alignment = column < alignments.count ? alignments[column] : .natural
			let style = AttributedText.ParagraphStyle(kind: .body, alignment: alignment)
			return AttributedText(runs: collectInlineRuns(Array(markup.children), style))
		}

		var headers: [AttributedText] = []
		for (column, head) in table.head.cells.enumerated() {
			headers.append(cell(head, column: column))
		}
		var rows: [[AttributedText]] = []
		for row in table.body.rows {
			var cells: [AttributedText] = []
			for (column, value) in row.cells.enumerated() {
				cells.append(cell(value, column: column))
			}
			rows.append(cells)
		}

		let model = AttributedText.Table(headers: headers, rows: rows, alignments: alignments)
		emitAttachmentParagraph(.table(model), fallback: tableFallbackText(model), kind: .table, context)
	}

	/// A readable plain-text rendering used as the table run's `text` so
	/// ``AttributedText/string`` stays meaningful on text-only platforms.
	private func tableFallbackText(_ table: AttributedText.Table) -> String {
		var lines: [String] = []
		if !table.headers.isEmpty {
			lines.append(table.headers.map { $0.string }.joined(separator: " | "))
		}
		for row in table.rows {
			lines.append(row.map { $0.string }.joined(separator: " | "))
		}
		return lines.joined(separator: "\n")
	}

	// MARK: Inline emission

	private func collectInlineRuns(
		_ inlines: [Markup], _ paragraph: AttributedText.ParagraphStyle
	) -> [AttributedText.Run] {
		var buffer: [AttributedText.Run] = []
		for inline in inlines {
			collectInline(inline, InlineStyle(), paragraph, into: &buffer)
		}
		return buffer
	}

	private func collectInline(
		_ markup: Markup,
		_ inline: InlineStyle,
		_ paragraph: AttributedText.ParagraphStyle,
		into buffer: inout [AttributedText.Run]
	) {
		switch markup {
		case let text as Text:
			emitText(text.string, inline, paragraph, into: &buffer)
		case let emphasis as Emphasis:
			var nested = inline; nested.italic = true
			descend(emphasis, nested, paragraph, into: &buffer)
		case let strong as Strong:
			var nested = inline; nested.bold = true
			descend(strong, nested, paragraph, into: &buffer)
		case let strikethrough as Strikethrough:
			var nested = inline; nested.strikethrough = true
			descend(strikethrough, nested, paragraph, into: &buffer)
		case let inlineCode as InlineCode:
			var attributes = attributes(inline, paragraph)
			attributes.code = true
			buffer.append(AttributedText.Run(inlineCode.code, attributes))
		case let link as Link:
			var nested = inline; nested.link = link.destination ?? ""
			descend(link, nested, paragraph, into: &buffer)
		case let image as Image:
			let alt = reverseSmart(swiftMarkdownPlainText(of: image))
			var attributes = attributes(inline, paragraph)
			attributes.attachment = .image(source: image.source ?? "", alt: alt, title: nil)
			buffer.append(AttributedText.Run(alt, attributes))
		case let inlineHTML as InlineHTML:
			// Raw HTML is emitted as literal text (no entity escaping — there is
			// no HTML target — and no smart-punct/footnote rewriting).
			buffer.append(AttributedText.Run(inlineHTML.rawHTML, attributes(inline, paragraph)))
		case is SoftBreak:
			buffer.append(AttributedText.Run(" ", attributes(inline, paragraph)))
		case is LineBreak:
			buffer.append(AttributedText.Run("\n", attributes(inline, paragraph)))
		default:
			descend(markup, inline, paragraph, into: &buffer)
		}
	}

	private func descend(
		_ markup: Markup,
		_ inline: InlineStyle,
		_ paragraph: AttributedText.ParagraphStyle,
		into buffer: inout [AttributedText.Run]
	) {
		for child in markup.children {
			collectInline(child, inline, paragraph, into: &buffer)
		}
	}

	/// Emits a `Text` node, splitting out `[^id]` footnote references (when a
	/// resolver is active) into superscript reference runs.
	private func emitText(
		_ string: String,
		_ inline: InlineStyle,
		_ paragraph: AttributedText.ParagraphStyle,
		into buffer: inout [AttributedText.Run]
	) {
		guard let resolver else {
			appendText(string, inline, paragraph, into: &buffer)
			return
		}
		for segment in resolver.resolve(string) {
			switch segment {
			case .text(let value):
				appendText(value, inline, paragraph, into: &buffer)
			case .reference(let number):
				var attributes = attributes(inline, paragraph)
				attributes.baseline = .superscript
				attributes.footnoteReference = number
				buffer.append(AttributedText.Run("\(number)", attributes))
			}
		}
	}

	private func appendText(
		_ string: String,
		_ inline: InlineStyle,
		_ paragraph: AttributedText.ParagraphStyle,
		into buffer: inout [AttributedText.Run]
	) {
		guard !string.isEmpty else { return }
		buffer.append(AttributedText.Run(reverseSmart(string), attributes(inline, paragraph)))
	}

	private func attributes(
		_ inline: InlineStyle, _ paragraph: AttributedText.ParagraphStyle
	) -> AttributedText.Attributes {
		AttributedText.Attributes(
			bold: inline.bold,
			italic: inline.italic,
			strikethrough: inline.strikethrough,
			code: inline.code,
			link: inline.link,
			baseline: inline.baseline,
			paragraph: paragraph
		)
	}

	private func reverseSmart(_ string: String) -> String {
		preserveSmartPunctuation ? string : reverseSmartPunctuation(string)
	}

	// MARK: Alert detection (ports SwiftMarkdownHTMLRenderer's logic)

	private func detectAlert(in quote: BlockQuote) -> (kind: AttributedText.AlertKind, terminator: Character)? {
		if let token = bracketedAlertToken(in: quote), let kind = AttributedText.AlertKind(token: token) {
			return (kind, "]")
		}
		if let token = doccAsideToken(in: quote), let kind = AttributedText.AlertKind(token: token) {
			return (kind, ":")
		}
		return nil
	}

	private func bracketedAlertToken(in quote: BlockQuote) -> String? {
		guard let paragraph = quote.child(at: 0) as? Paragraph,
		      let text = paragraph.child(at: 0) as? Text else { return nil }
		let raw = text.string
		guard raw.hasPrefix("[!"), let closing = raw.firstIndex(of: "]") else { return nil }
		return String(raw[raw.index(raw.startIndex, offsetBy: 2)..<closing])
	}

	private func doccAsideToken(in quote: BlockQuote) -> String? {
		guard let paragraph = quote.child(at: 0) as? Paragraph,
		      let text = paragraph.child(at: 0) as? Text,
		      let colon = text.string.firstIndex(of: ":") else { return nil }
		let token = String(text.string[..<colon])
		guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else { return nil }
		return token
	}
}

// MARK: - Smart punctuation reversal (shared policy with the HTML renderer)

private func reverseSmartPunctuation(_ string: String) -> String {
	guard string.contains(where: isSmartCharacter) else { return string }
	var result = ""
	result.reserveCapacity(string.count)
	for character in string {
		switch character {
		case "\u{2018}", "\u{2019}": result.append("'")   // ‘ ’
		case "\u{201C}", "\u{201D}": result.append("\"")  // “ ”
		case "\u{2013}": result.append("--")               // –
		case "\u{2014}": result.append("---")              // —
		case "\u{2026}": result.append("...")              // …
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
