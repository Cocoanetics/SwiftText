import Foundation
import Markdown
import SwiftTextMarkdown

/// Builds `DocxWriter.Block` and `DocxWriter.Run` values from a swift-markdown
/// AST. Internal helper for `MarkdownToDocx`.
enum MarkdownDocxBuilder {

	/// The document model built from Markdown: body blocks plus any footnotes.
	struct Build {
		var blocks: [DocxWriter.Block]
		var footnotes: [DocxWriter.Footnote]
	}

	/// Builds body blocks and footnotes from Markdown. `[^id]` references and
	/// `[^id]: …` definitions are parsed with ``MarkdownFootnoteParser`` (which
	/// swift-markdown can't do natively) and emitted as native Word footnotes.
	static func build(from markdown: String) -> Build {
		let (cleaned, definitions) = MarkdownFootnoteParser.extractDefinitions(from: markdown)

		// Fast path: no footnote definitions -> nothing to resolve.
		guard !definitions.isEmpty else {
			return Build(blocks: blocks(from: markdown, resolver: nil), footnotes: [])
		}

		let resolver = MarkdownFootnoteResolver(definitionIDs: definitions.map(\.id))

		// Body blocks: walking the body in document order assigns footnote
		// numbers in source order of first reference.
		let bodyBlocks = blocks(from: cleaned, resolver: resolver)

		// Render each referenced definition's body into footnote blocks. A
		// definition can be referenced only from inside another definition that
		// appears earlier in source, so re-scan until a pass renders nothing new.
		var blocksByNumber: [Int: [DocxWriter.Block]] = [:]
		var renderedIDs = Set<String>()
		var renderedNew = true
		while renderedNew {
			renderedNew = false
			for definition in definitions where !renderedIDs.contains(definition.id) {
				guard let number = resolver.number(forID: definition.id) else {
					// Definition not referenced (yet) — skip it.
					continue
				}
				blocksByNumber[number] = blocks(from: definition.body, resolver: resolver)
				renderedIDs.insert(definition.id)
				renderedNew = true
			}
		}

		let footnotes = blocksByNumber
			.sorted { $0.key < $1.key }
			.map { DocxWriter.Footnote(id: $0.key, blocks: $0.value) }
		return Build(blocks: bodyBlocks, footnotes: footnotes)
	}

	static func blocks(from markdown: String) -> [DocxWriter.Block] {
		build(from: markdown).blocks
	}

	private static func blocks(from markdown: String, resolver: MarkdownFootnoteResolver?) -> [DocxWriter.Block] {
		let document = Document(parsing: markdown, options: [])
		var visitor = BlockVisitor(resolver: resolver)
		visitor.visit(document)
		return visitor.blocks
	}

	/// Parses inline Markdown into a flat run list. Treats the input as the
	/// inline content of a paragraph — block-level constructs are ignored.
	static func runs(fromInline text: String) -> [DocxWriter.Run] {
		let document = Document(parsing: text, options: [])
		guard let firstParagraph = document.child(at: 0) as? Paragraph else { return [] }
		return runs(from: firstParagraph, resolver: nil)
	}

	static func runs(from inlineContainer: Markup, resolver: MarkdownFootnoteResolver?) -> [DocxWriter.Run] {
		var collector = RunCollector(resolver: resolver)
		collector.collect(from: inlineContainer)
		return collector.runs
	}
}

// MARK: - Inline -> [Run]

private struct RunStyle {
	var bold: Bool = false
	var italic: Bool = false
	var strike: Bool = false
	var code: Bool = false
	var link: String? = nil
}

private struct RunCollector {
	var runs: [DocxWriter.Run] = []
	private var style = RunStyle()
	/// When present, `[^id]` references in `Text` nodes become footnote runs.
	let resolver: MarkdownFootnoteResolver?

	init(resolver: MarkdownFootnoteResolver?) {
		self.resolver = resolver
	}

	mutating func collect(from container: Markup) {
		for child in container.children { visit(child) }
	}

	private mutating func visit(_ markup: Markup) {
		switch markup {
		case let text as Text:
			appendResolvingFootnotes(in: text.string)
		case let emphasis as Emphasis:
			withStyle({ $0.italic = true }) {
				$0.collect(from: emphasis)
			}
		case let strong as Strong:
			withStyle({ $0.bold = true }) {
				$0.collect(from: strong)
			}
		case let strikethrough as Strikethrough:
			withStyle({ $0.strike = true }) {
				$0.collect(from: strikethrough)
			}
		case let inlineCode as InlineCode:
			runs.append(DocxWriter.Run(
				text: inlineCode.code,
				bold: style.bold,
				italic: style.italic,
				strike: style.strike,
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
			strike: style.strike,
			code: style.code,
			link: style.link
		))
	}

	/// Appends a plain `Text` node, splitting out any `[^id]` footnote
	/// references (when a resolver is active) into dedicated footnote-reference
	/// runs. Without a resolver this is just `append(text:)`.
	private mutating func appendResolvingFootnotes(in string: String) {
		guard let resolver else {
			append(text: reverseSmartPunct(string))
			return
		}
		for segment in resolver.resolve(string) {
			switch segment {
			case .text(let value):
				if !value.isEmpty { append(text: reverseSmartPunct(value)) }
			case .reference(let number):
				runs.append(DocxWriter.Run(text: "", footnoteRef: number))
			}
		}
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
	/// Shared across the whole document so footnote numbers stay in source order.
	let resolver: MarkdownFootnoteResolver?

	init(resolver: MarkdownFootnoteResolver?) {
		self.resolver = resolver
	}

	mutating func defaultVisit(_ markup: Markup) {
		for child in markup.children { visit(child) }
	}

	mutating func visitDocument(_ document: Document) {
		for child in document.children { visit(child) }
	}

	mutating func visitParagraph(_ paragraph: Paragraph) {
		// A paragraph that is solely an image becomes an embedded inline image (the
		// writer resolves + sizes it). Images mixed with text still fall back to the
		// italic alt-text placeholder produced by RunCollector.
		let children = Array(paragraph.children)
		if children.count == 1, let image = children.first as? Image,
		   let source = image.source, !source.isEmpty {
			let alt = reverseSmartPunct(swiftMarkdownPlainText(of: image))
			blocks.append(.image(source: source, alt: alt))
			return
		}
		blocks.append(.paragraph(runs: MarkdownDocxBuilder.runs(from: paragraph, resolver: resolver)))
	}

	mutating func visitHeading(_ heading: Heading) {
		let level = max(1, min(heading.level, 6))
		blocks.append(.heading(level: level, runs: MarkdownDocxBuilder.runs(from: heading, resolver: resolver)))
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
		var inner = BlockVisitor(resolver: resolver)
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
		let runs = inlineParagraphs.flatMap { MarkdownDocxBuilder.runs(from: $0, resolver: resolver) }
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
			headers.append(MarkdownDocxBuilder.runs(from: cell, resolver: resolver))
		}
		var rows: [[[DocxWriter.Run]]] = []
		for row in table.body.rows {
			var cells: [[DocxWriter.Run]] = []
			for cell in row.cells {
				cells.append(MarkdownDocxBuilder.runs(from: cell, resolver: resolver))
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
