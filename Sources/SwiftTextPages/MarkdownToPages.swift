import Foundation
import Markdown
import SwiftTextMarkdown

/// Converts Markdown text to a Pages (`.pages`) file, backed by swift-markdown's
/// parser — the Pages counterpart to `MarkdownToDocx`.
///
/// ```swift
/// try MarkdownToPages.convert(markdownString, to: outputURL)
/// ```
public enum MarkdownToPages {
	/// Converts Markdown text to a `.pages` file at the given URL.
	public static func convert(_ markdown: String, to url: URL) throws {
		let paragraphs = MarkdownPagesBuilder.paragraphs(from: markdown)
		try PagesWriter().write(paragraphs: paragraphs, to: url)
	}

	/// Parses Markdown into the body paragraphs the writer renders.
	static func paragraphs(_ markdown: String) -> [BodyParagraph] {
		MarkdownPagesBuilder.paragraphs(from: markdown)
	}
}

/// Walks a swift-markdown AST into `BodyParagraph` values, mirroring
/// `MarkdownDocxBuilder` so Pages output supports the same Markdown features the
/// DOCX writer does. Everything flattens into the document's single text storage,
/// styled via run tables.
enum MarkdownPagesBuilder {
	static func paragraphs(from markdown: String) -> [BodyParagraph] {
		let document = Document(parsing: markdown, options: [])
		var visitor = BlockVisitor()
		visitor.visit(document)
		return visitor.paragraphs
	}
}

// MARK: - Inline → text + style runs

/// Flattens an inline container into a paragraph's text plus its styled runs,
/// tracking UTF-16 offsets (the units the run tables and reader use).
private struct InlineCollector {
	private(set) var text = ""
	private(set) var runs: [BodyParagraph.StyledRun] = []
	private var style: InlineStyle

	init(base: InlineStyle = InlineStyle()) {
		self.style = base
	}

	mutating func collect(from container: Markup) {
		for child in container.children { visit(child) }
	}

	/// Appends literal text outside any inline markup (e.g. a separator).
	mutating func appendLiteral(_ string: String) {
		append(string, style: style)
	}

	private mutating func visit(_ markup: Markup) {
		switch markup {
		case let text as Text:
			append(reverseSmartPunct(text.string), style: style)
		case let emphasis as Emphasis:
			withStyle({ $0.italic = true }) { $0.collect(from: emphasis) }
		case let strong as Strong:
			withStyle({ $0.bold = true }) { $0.collect(from: strong) }
		case is Strikethrough:
			withStyle({ $0.strikethrough = true }) { $0.collect(from: markup) }
		case let inlineCode as InlineCode:
			var codeStyle = style
			codeStyle.code = true
			append(inlineCode.code, style: codeStyle)
		case let link as Link:
			// Style the link text (underline). A clickable URL attachment is a
			// separate, heavier construct; the visible styling matches here.
			withStyle({ $0.link = true }) { $0.collect(from: link) }
		case let image as Image:
			// Match the DOCX writer: images become italic placeholder text.
			let alt = reverseSmartPunct(swiftMarkdownPlainText(of: image))
			var imageStyle = style
			imageStyle.italic = true
			append(alt.isEmpty ? "[image]" : alt, style: imageStyle)
		case let inlineHTML as InlineHTML:
			append(inlineHTML.rawHTML, style: style)
		case is SoftBreak:
			append(" ", style: style)          // join soft-wrapped lines with a space
		case is LineBreak:
			append("\u{2028}", style: style)    // hard break: line separator within the paragraph
		default:
			collect(from: markup)
		}
	}

	private mutating func append(_ string: String, style: InlineStyle) {
		guard !string.isEmpty else { return }
		let start = text.utf16.count
		text += string
		if !style.isPlain {
			runs.append(.init(start: start, length: string.utf16.count, style: style))
		}
	}

	private mutating func withStyle(_ apply: (inout InlineStyle) -> Void, _ body: (inout InlineCollector) -> Void) {
		let saved = style
		apply(&style)
		body(&self)
		style = saved
	}
}

// MARK: - Blocks → [BodyParagraph]

private struct BlockVisitor: MarkupVisitor {
	typealias Result = Void

	var paragraphs: [BodyParagraph] = []
	private var listDepth = 0
	private var blockQuoteDepth = 0

	mutating func defaultVisit(_ markup: Markup) {
		for child in markup.children { visit(child) }
	}

	mutating func visitDocument(_ document: Document) {
		for child in document.children { visit(child) }
	}

	mutating func visitParagraph(_ paragraph: Paragraph) {
		var collector = InlineCollector()
		collector.collect(from: paragraph)
		paragraphs.append(BodyParagraph(
			text: collector.text,
			paragraphStyle: PagesStyleID.body,
			blockQuote: blockQuoteDepth > 0,
			runs: collector.runs
		))
	}

	mutating func visitHeading(_ heading: Heading) {
		var collector = InlineCollector()
		collector.collect(from: heading)
		paragraphs.append(BodyParagraph(
			text: collector.text,
			paragraphStyle: Self.headingStyle(level: heading.level),
			runs: collector.runs
		))
	}

	mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
		var code = codeBlock.code
		if code.hasSuffix("\n") { code.removeLast() }
		// One paragraph per line, the whole line in a monospace run.
		for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
			let text = String(line)
			let runs = text.isEmpty
				? []
				: [BodyParagraph.StyledRun(start: 0, length: text.utf16.count, style: InlineStyle(code: true))]
			paragraphs.append(BodyParagraph(text: text, paragraphStyle: PagesStyleID.body, runs: runs))
		}
	}

	mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
		blockQuoteDepth += 1
		defer { blockQuoteDepth -= 1 }
		for child in blockQuote.children { visit(child) }
	}

	mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
		// A horizontal rule rendered as a full-width line of box-drawing characters.
		paragraphs.append(BodyParagraph(text: String(repeating: "\u{2500}", count: 40), paragraphStyle: PagesStyleID.body))
	}

	mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
		emitListItems(in: unorderedList, ordered: false)
	}

	mutating func visitOrderedList(_ orderedList: OrderedList) {
		emitListItems(in: orderedList, ordered: true)
	}

	private mutating func emitListItems(in list: ListItemContainer, ordered: Bool) {
		let level = listDepth
		for child in list.children {
			guard let item = child as? ListItem else { continue }
			emit(listItem: item, ordered: ordered, level: level)
		}
	}

	private mutating func emit(listItem: ListItem, ordered: Bool, level: Int) {
		var inlineParagraphs: [Paragraph] = []
		var nestedLists: [Markup] = []
		for child in listItem.children {
			if let paragraph = child as? Paragraph {
				inlineParagraphs.append(paragraph)
			} else if child is UnorderedList || child is OrderedList {
				nestedLists.append(child)
			}
		}

		var collector = InlineCollector()
		for (index, paragraph) in inlineParagraphs.enumerated() {
			if index > 0 { collector.appendLiteral(" ") }
			collector.collect(from: paragraph)
		}
		paragraphs.append(BodyParagraph(
			text: collector.text,
			paragraphStyle: PagesStyleID.body,
			listStyle: ordered ? PagesStyleID.numberedList : PagesStyleID.bulletList,
			listLevel: level,
			runs: collector.runs
		))

		listDepth = level + 1
		defer { listDepth = level }
		for nested in nestedLists { visit(nested) }
	}

	mutating func visitTable(_ table: Table) {
		// Rendered as tab-separated rows (header bold). This preserves all cell
		// content and inline styling; a native iWork table grid is a heavier,
		// separate construct.
		func appendRow(_ cells: [Table.Cell], header: Bool) {
			var collector = InlineCollector(base: header ? InlineStyle(bold: true) : InlineStyle())
			for (index, cell) in cells.enumerated() {
				if index > 0 { collector.appendLiteral("\t") }
				collector.collect(from: cell)
			}
			paragraphs.append(BodyParagraph(text: collector.text, paragraphStyle: PagesStyleID.body, runs: collector.runs))
		}
		appendRow(Array(table.head.cells), header: true)
		for row in table.body.rows {
			appendRow(Array(row.cells), header: false)
		}
	}

	mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) {
		// Not representable; the DOCX writer drops these too.
	}

	/// Maps a Markdown heading level to a template paragraph style.
	private static func headingStyle(level: Int) -> UInt64 {
		switch level {
		case 1: return PagesStyleID.heading1
		case 2: return PagesStyleID.heading2
		default: return PagesStyleID.heading3
		}
	}
}

// MARK: - Smart-punctuation reversal (cmark forces it on; undo to match source)

private func reverseSmartPunct(_ string: String) -> String {
	guard string.contains(where: isSmartCharacter) else { return string }
	var result = ""
	result.reserveCapacity(string.count)
	for character in string {
		switch character {
		case "\u{2018}", "\u{2019}": result.append("'")
		case "\u{201C}", "\u{201D}": result.append("\"")
		case "\u{2013}": result.append("--")
		case "\u{2014}": result.append("---")
		case "\u{2026}": result.append("...")
		default: result.append(character)
		}
	}
	return result
}

private func isSmartCharacter(_ character: Character) -> Bool {
	switch character {
	case "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "\u{2013}", "\u{2014}", "\u{2026}":
		return true
	default:
		return false
	}
}
