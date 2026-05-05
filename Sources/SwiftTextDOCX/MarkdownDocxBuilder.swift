import Foundation
import Markdown
import SwiftTextMarkdown

/// Builds `DocxWriter.Block` and `DocxWriter.Run` values from a swift-markdown
/// AST. Internal helper for `MarkdownToDocx`.
enum MarkdownDocxBuilder {

	static func blocks(from markdown: String) -> [DocxWriter.Block] {
		let document = Document(parsing: markdown, options: [])
		var visitor = BlockVisitor()
		visitor.visit(document)
		return visitor.blocks
	}

	/// Parses inline Markdown into a flat run list. Treats the input as the
	/// inline content of a paragraph — block-level constructs are ignored.
	static func runs(fromInline text: String) -> [DocxWriter.Run] {
		let document = Document(parsing: text, options: [])
		guard let firstParagraph = document.child(at: 0) as? Paragraph else { return [] }
		return runs(from: firstParagraph)
	}

	static func runs(from inlineContainer: Markup) -> [DocxWriter.Run] {
		var collector = RunCollector()
		collector.collect(from: inlineContainer)
		return collector.runs
	}
}

// MARK: - Inline -> [Run]

private struct RunStyle {
	var bold: Bool = false
	var italic: Bool = false
	var code: Bool = false
	var link: String? = nil
}

private struct RunCollector {
	var runs: [DocxWriter.Run] = []
	private var style = RunStyle()

	mutating func collect(from container: Markup) {
		for child in container.children { visit(child) }
	}

	private mutating func visit(_ markup: Markup) {
		switch markup {
		case let text as Text:
			append(text: reverseSmartPunct(text.string))
		case let emphasis as Emphasis:
			withStyle({ $0.italic = true }) {
				$0.collect(from: emphasis)
			}
		case let strong as Strong:
			withStyle({ $0.bold = true }) {
				$0.collect(from: strong)
			}
		case is Strikethrough:
			// DocxWriter.Run has no strikethrough field today, so we drop the
			// marker and emit the inner content as a regular styled span. If a
			// future writer adds support, this is the place to thread it.
			collect(from: markup)
		case let inlineCode as InlineCode:
			runs.append(DocxWriter.Run(
				text: inlineCode.code,
				bold: style.bold,
				italic: style.italic,
				code: true,
				link: style.link
			))
		case let link as Link:
			withStyle({ $0.link = link.destination ?? "" }) {
				$0.collect(from: link)
			}
		case let image as Image:
			// Legacy renderer emitted images as italic placeholder text. Keep
			// that behavior — DOCX writer doesn't yet inline images. Walk all
			// descendants so alt text from nested inline formatting is
			// preserved (e.g. `![*logo*](...)` keeps "logo" instead of
			// falling through to the `[image]` placeholder).
			let alt = reverseSmartPunct(swiftMarkdownPlainText(of: image))
			let display = alt.isEmpty ? "[image]" : alt
			runs.append(DocxWriter.Run(text: display, italic: true))
		case let inlineHTML as InlineHTML:
			append(text: inlineHTML.rawHTML)
		case is SoftBreak:
			append(text: " ")  // legacy joined paragraph lines with " "
		case is LineBreak:
			append(text: "\n")
		default:
			collect(from: markup)
		}
	}

	private mutating func append(text: String) {
		runs.append(DocxWriter.Run(
			text: text,
			bold: style.bold,
			italic: style.italic,
			code: style.code,
			link: style.link
		))
	}

	private mutating func withStyle(_ apply: (inout RunStyle) -> Void, _ body: (inout RunCollector) -> Void) {
		let saved = style
		apply(&style)
		body(&self)
		style = saved
	}
}

// MARK: - Document -> [DocxWriter.Block]

private struct BlockVisitor: MarkupVisitor {
	typealias Result = Void

	var blocks: [DocxWriter.Block] = []
	private var listLevel: Int = 0

	mutating func defaultVisit(_ markup: Markup) {
		for child in markup.children { visit(child) }
	}

	mutating func visitDocument(_ document: Document) {
		for child in document.children { visit(child) }
	}

	mutating func visitParagraph(_ paragraph: Paragraph) {
		blocks.append(.paragraph(runs: MarkdownDocxBuilder.runs(from: paragraph)))
	}

	mutating func visitHeading(_ heading: Heading) {
		let level = max(1, min(heading.level, 6))
		blocks.append(.heading(level: level, runs: MarkdownDocxBuilder.runs(from: heading)))
	}

	mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
		var code = codeBlock.code
		if code.hasSuffix("\n") { code.removeLast() }
		blocks.append(.codeBlock(language: codeBlock.language, text: code))
	}

	mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
		blocks.append(.horizontalRule)
	}

	mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
		var inner = BlockVisitor()
		inner.listLevel = listLevel
		for child in blockQuote.children { inner.visit(child) }
		blocks.append(.blockquote(blocks: inner.blocks))
	}

	mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
		emitListItems(in: unorderedList, ordered: false)
	}

	mutating func visitOrderedList(_ orderedList: OrderedList) {
		emitListItems(in: orderedList, ordered: true)
	}

	private mutating func emitListItems(in list: ListItemContainer, ordered: Bool) {
		for child in list.children {
			guard let item = child as? ListItem else { continue }
			emit(listItem: item, ordered: ordered, level: listLevel)
		}
	}

	private mutating func emit(listItem: ListItem, ordered: Bool, level: Int) {
		// Emit the first paragraph of the item as the bulleted line, then any
		// further content inline. Nested lists are emitted at level+1.
		var inlineParagraphs: [Paragraph] = []
		var nestedLists: [Markup] = []
		for child in listItem.children {
			if let paragraph = child as? Paragraph {
				inlineParagraphs.append(paragraph)
			} else if child is UnorderedList || child is OrderedList {
				nestedLists.append(child)
			}
		}
		let runs = inlineParagraphs.flatMap { MarkdownDocxBuilder.runs(from: $0) }
		blocks.append(.listItem(ordered: ordered, level: level, runs: runs))

		listLevel = level + 1
		defer { listLevel = level }
		for nested in nestedLists {
			visit(nested)
		}
	}

	mutating func visitTable(_ table: Table) {
		let alignments: [DocxWriter.ColumnAlignment] = table.columnAlignments.map { alignment in
			switch alignment {
			case .left, .none: return .left
			case .center: return .center
			case .right: return .right
			}
		}
		var headers: [[DocxWriter.Run]] = []
		for cell in table.head.cells {
			headers.append(MarkdownDocxBuilder.runs(from: cell))
		}
		var rows: [[[DocxWriter.Run]]] = []
		for row in table.body.rows {
			var cells: [[DocxWriter.Run]] = []
			for cell in row.cells {
				cells.append(MarkdownDocxBuilder.runs(from: cell))
			}
			rows.append(cells)
		}
		blocks.append(.table(headers: headers, rows: rows, alignments: alignments))
	}

	// HTML blocks aren't representable in our DocxWriter block model — the
	// legacy parser dropped them silently. Match that.
	mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) {}
}

// MARK: - Smart-punct reversal

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
	case "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}",
		 "\u{2013}", "\u{2014}", "\u{2026}":
		return true
	default:
		return false
	}
}
