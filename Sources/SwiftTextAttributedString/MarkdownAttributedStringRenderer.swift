import Foundation
import Markdown
import SwiftTextMarkdown

/// Markdown → Foundation `AttributedString` renderer built on swift-markdown's AST.
///
/// The output matches the structure Foundation's own `AttributedString(markdown:)`
/// produces — block hierarchy in `presentationIntent` (with a shared, pre-order
/// identity counter and **no** literal newlines between blocks), inline styling
/// in `inlinePresentationIntent`, and links in `.link` — so the result renders
/// and round-trips like any Foundation attributed string.
///
/// Unlike Foundation's built-in parser, it uses swift-markdown (the same AST as
/// the package's HTML/DOCX/Pages paths), so it covers the full GFM superset:
/// tables with alignment, strikethrough, task lists, and — via a custom
/// ``SwiftTextMarkdownAttributes`` scope that Foundation's intents can't express
/// — `[^id]` footnotes, GitHub/DocC alerts, and image sources.
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
public enum MarkdownAttributedStringRenderer {

	/// Rendering options.
	public struct Options: OptionSet, Sendable {
		public let rawValue: Int
		public init(rawValue: Int) { self.rawValue = rawValue }

		/// Keep cmark-gfm's smart typographic characters instead of reversing
		/// them to their literal source spelling (`"`, `'`, `--`, `---`, `...`).
		public static let preserveSmartPunctuation = Options(rawValue: 1 << 0)
	}

	/// Converts Markdown to an `AttributedString`, expanding `[^id]` footnote
	/// references and appending a definitions block for `[^id]: …` definitions.
	public static func convert(_ markdown: String, options: Options = []) -> AttributedString {
		let (cleaned, definitions) = MarkdownFootnoteParser.extractDefinitions(from: markdown)

		guard !definitions.isEmpty else {
			let builder = Builder(options: options, resolver: nil)
			builder.emitBlocks(Document(parsing: cleaned, options: []).children, EmitContext())
			return builder.result
		}

		let resolver = MarkdownFootnoteResolver(definitionIDs: definitions.map(\.id))
		let builder = Builder(options: options, resolver: resolver)

		// Body first so footnote numbers are assigned in source order.
		builder.emitBlocks(Document(parsing: cleaned, options: []).children, EmitContext())

		// Then definitions, in the SAME builder so presentation-intent identities
		// stay globally unique. Re-scan until a pass renders nothing new, so a
		// definition referenced only from another definition still resolves.
		var renderedIDs = Set<String>()
		var renderedNew = true
		var pending: [(number: Int, body: String)] = []
		while renderedNew {
			renderedNew = false
			for definition in definitions where !renderedIDs.contains(definition.id) {
				guard let number = resolver.number(forID: definition.id) else { continue }
				pending.append((number, definition.body))
				renderedIDs.insert(definition.id)
				renderedNew = true
			}
		}
		for entry in pending.sorted(by: { $0.number < $1.number }) {
			builder.emitFootnoteDefinition(entry.body, number: entry.number)
		}

		return builder.result
	}

	/// Renders an already-parsed `Document` (no footnote extraction — use
	/// ``convert(_:options:)`` for that).
	public static func convert(document: Document, options: Options = []) -> AttributedString {
		let builder = Builder(options: options, resolver: nil)
		builder.emitBlocks(document.children, EmitContext())
		return builder.result
	}
}

// MARK: - Convenience initializers

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension AttributedString {
	/// Builds an attributed string from Markdown using SwiftText's renderer
	/// (full GFM + footnotes + alerts), as opposed to Foundation's built-in
	/// `init(markdown:)`.
	public init(
		swiftTextMarkdown markdown: String,
		options: MarkdownAttributedStringRenderer.Options = []
	) {
		self = MarkdownAttributedStringRenderer.convert(markdown, options: options)
	}
}

// MARK: - Emit context

/// State threaded down the block tree: the enclosing block intent (the parent
/// for the next leaf), and the alert / footnote-definition tags applied to runs.
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private struct EmitContext {
	var parent: PresentationIntent?
	var alert: MarkdownAlert?
	var footnoteDefinition: Int?

	func childOf(_ intent: PresentationIntent) -> EmitContext {
		var copy = self
		copy.parent = intent
		return copy
	}
}

/// The inline styling accumulated while descending inline nodes.
private struct InlineStyle {
	var intent: InlinePresentationIntent = []
	var link: URL?
}

// MARK: - Builder

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
private final class Builder {
	private(set) var result = AttributedString()
	private var nextIdentity = 1
	private let options: MarkdownAttributedStringRenderer.Options
	private let resolver: MarkdownFootnoteResolver?

	init(options: MarkdownAttributedStringRenderer.Options, resolver: MarkdownFootnoteResolver?) {
		self.options = options
		self.resolver = resolver
	}

	private var preserveSmartPunctuation: Bool {
		options.contains(.preserveSmartPunctuation)
	}

	/// Identities are assigned in pre-order DFS (parent before children, in
	/// document order) — the same scheme Foundation's Markdown parser uses.
	private func nextID() -> Int {
		defer { nextIdentity += 1 }
		return nextIdentity
	}

	private func intent(
		_ kind: PresentationIntent.Kind, parent: PresentationIntent?
	) -> PresentationIntent {
		PresentationIntent(kind, identity: nextID(), parent: parent)
	}

	// MARK: Block emission

	func emitBlocks(_ children: some Sequence<Markup>, _ context: EmitContext) {
		for child in children { emitBlock(child, context) }
	}

	private func emitBlock(_ markup: Markup, _ context: EmitContext) {
		switch markup {
		case let paragraph as Paragraph:
			let leaf = intent(.paragraph, parent: context.parent)
			emitInlines(paragraph.children, leaf: leaf, context)
		case let heading as Heading:
			let level = max(1, min(heading.level, 6))
			let leaf = intent(.header(level: level), parent: context.parent)
			emitInlines(heading.children, leaf: leaf, context)
		case let codeBlock as CodeBlock:
			// Foundation keeps the code's trailing newline; mirror that.
			let leaf = intent(.codeBlock(languageHint: codeBlock.language), parent: context.parent)
			append(codeBlock.code, intent: [], leaf: leaf, context)
		case is ThematicBreak:
			let leaf = intent(.thematicBreak, parent: context.parent)
			append(thematicBreakText, intent: [], leaf: leaf, context)
		case let htmlBlock as HTMLBlock:
			// Foundation gives HTML blocks no presentation intent + `.blockHTML`.
			append(htmlBlock.rawHTML, intent: .blockHTML, leaf: nil, context)
		case let blockQuote as BlockQuote:
			emitBlockQuote(blockQuote, context)
		case let unordered as UnorderedList:
			emitList(unordered, ordered: false, context)
		case let ordered as OrderedList:
			emitList(ordered, ordered: true, context)
		case let table as Table:
			emitTable(table, context)
		default:
			emitBlocks(markup.children, context)
		}
	}

	// MARK: Blockquotes & alerts

	private func emitBlockQuote(_ blockQuote: BlockQuote, _ context: EmitContext) {
		let quoteIntent = intent(.blockQuote, parent: context.parent)

		if let detected = detectAlert(in: blockQuote) {
			var alertContext = context.childOf(quoteIntent)
			alertContext.alert = detected.kind
			let children = Array(blockQuote.children)
			for (index, child) in children.enumerated() {
				if index == 0, let paragraph = child as? Paragraph {
					let inlines = strippedAlertMarker(in: paragraph, terminator: detected.terminator)
					guard !inlines.isEmpty else { continue }
					let leaf = intent(.paragraph, parent: quoteIntent)
					emitInlines(inlines, leaf: leaf, alertContext)
				} else {
					emitBlock(child, alertContext)
				}
			}
			return
		}

		emitBlocks(blockQuote.children, context.childOf(quoteIntent))
	}

	// MARK: Lists

	private func emitList(_ list: ListItemContainer, ordered: Bool, _ context: EmitContext) {
		let listIntent = intent(ordered ? .orderedList : .unorderedList, parent: context.parent)
		var ordinal = ordered ? orderedListStart(list) : 1
		for case let item as ListItem in list.children {
			let itemIntent = intent(.listItem(ordinal: ordinal), parent: listIntent)
			emitBlocks(item.children, context.childOf(itemIntent))
			ordinal += 1
		}
	}

	private func orderedListStart(_ list: ListItemContainer) -> Int {
		(list as? OrderedList).map { Int($0.startIndex) } ?? 1
	}

	// MARK: Tables

	private func emitTable(_ table: Table, _ context: EmitContext) {
		let columns = table.columnAlignments.map { alignment -> PresentationIntent.TableColumn in
			switch alignment {
			case .center: return PresentationIntent.TableColumn(alignment: .center)
			case .right: return PresentationIntent.TableColumn(alignment: .right)
			case .left, .none: return PresentationIntent.TableColumn(alignment: .left)
			}
		}
		let tableIntent = intent(.table(columns: columns), parent: context.parent)

		let headerRow = intent(.tableHeaderRow, parent: tableIntent)
		for (column, cell) in table.head.cells.enumerated() {
			let cellIntent = intent(.tableCell(columnIndex: column), parent: headerRow)
			emitInlines(cell.children, leaf: cellIntent, context)
		}

		var rowIndex = 1
		for row in table.body.rows {
			let rowIntent = intent(.tableRow(rowIndex: rowIndex), parent: tableIntent)
			for (column, cell) in row.cells.enumerated() {
				let cellIntent = intent(.tableCell(columnIndex: column), parent: rowIntent)
				emitInlines(cell.children, leaf: cellIntent, context)
			}
			rowIndex += 1
		}
	}

	// MARK: Footnote definitions

	func emitFootnoteDefinition(_ body: String, number: Int) {
		var context = EmitContext()
		context.footnoteDefinition = number
		let blocks = Array(Document(parsing: body, options: []).children)

		guard !blocks.isEmpty else {
			let leaf = intent(.paragraph, parent: nil)
			appendFootnoteLabel(number, leaf: leaf, context)
			return
		}

		for (index, block) in blocks.enumerated() {
			if index == 0, let paragraph = block as? Paragraph {
				let leaf = intent(.paragraph, parent: nil)
				appendFootnoteLabel(number, leaf: leaf, context)
				emitInlines(paragraph.children, leaf: leaf, context)
			} else {
				emitBlock(block, context)
			}
		}
	}

	private func appendFootnoteLabel(_ number: Int, leaf: PresentationIntent, _ context: EmitContext) {
		append("\(number). ", intent: .stronglyEmphasized, leaf: leaf, context)
	}

	// MARK: Inline emission

	private func emitInlines(_ inlines: some Sequence<Markup>, leaf: PresentationIntent?, _ context: EmitContext) {
		for inline in inlines {
			emitInline(inline, InlineStyle(), leaf: leaf, context)
		}
	}

	private func emitInline(
		_ markup: Markup, _ style: InlineStyle, leaf: PresentationIntent?, _ context: EmitContext
	) {
		switch markup {
		case let text as Text:
			emitText(text.string, style, leaf: leaf, context)
		case let emphasis as Emphasis:
			descend(emphasis, inserting: .emphasized, style, leaf: leaf, context)
		case let strong as Strong:
			descend(strong, inserting: .stronglyEmphasized, style, leaf: leaf, context)
		case let strikethrough as Strikethrough:
			descend(strikethrough, inserting: .strikethrough, style, leaf: leaf, context)
		case let inlineCode as InlineCode:
			var intent = style.intent
			intent.insert(.code)
			append(inlineCode.code, intent: intent, link: style.link, leaf: leaf, context)
		case let link as Link:
			var nested = style
			nested.link = (link.destination).flatMap(URL.init(string:)) ?? style.link
			for child in link.children { emitInline(child, nested, leaf: leaf, context) }
		case let image as Image:
			let alt = reverseSmart(swiftMarkdownPlainText(of: image))
			append(alt, intent: style.intent, link: style.link, leaf: leaf, context, imageSource: image.source)
		case let inlineHTML as InlineHTML:
			var intent = style.intent
			intent.insert(.inlineHTML)
			append(inlineHTML.rawHTML, intent: intent, link: style.link, leaf: leaf, context)
		case is SoftBreak:
			var intent = style.intent
			intent.insert(.softBreak)
			append(" ", intent: intent, link: style.link, leaf: leaf, context)
		case is LineBreak:
			var intent = style.intent
			intent.insert(.lineBreak)
			append("\n", intent: intent, link: style.link, leaf: leaf, context)
		default:
			for child in markup.children { emitInline(child, style, leaf: leaf, context) }
		}
	}

	private func descend(
		_ markup: Markup,
		inserting trait: InlinePresentationIntent,
		_ style: InlineStyle,
		leaf: PresentationIntent?,
		_ context: EmitContext
	) {
		var nested = style
		nested.intent.insert(trait)
		for child in markup.children { emitInline(child, nested, leaf: leaf, context) }
	}

	/// Emits a `Text` node, splitting `[^id]` references (when a resolver is
	/// active) into footnote-reference runs tagged with their number.
	private func emitText(_ string: String, _ style: InlineStyle, leaf: PresentationIntent?, _ context: EmitContext) {
		guard let resolver else {
			append(reverseSmart(string), intent: style.intent, link: style.link, leaf: leaf, context)
			return
		}
		for segment in resolver.resolve(string) {
			switch segment {
			case .text(let value):
				append(reverseSmart(value), intent: style.intent, link: style.link, leaf: leaf, context)
			case .reference(let number):
				append("\(number)", intent: style.intent, link: style.link, leaf: leaf, context, footnoteReference: number)
			}
		}
	}

	// MARK: Append

	private func append(
		_ text: String,
		intent: InlinePresentationIntent,
		link: URL? = nil,
		leaf: PresentationIntent?,
		_ context: EmitContext,
		footnoteReference: Int? = nil,
		imageSource: String? = nil
	) {
		guard !text.isEmpty else { return }
		var container = AttributeContainer()
		if !intent.isEmpty { container.inlinePresentationIntent = intent }
		if let link { container.link = link }
		if let leaf { container.presentationIntent = leaf }
		if let alert = context.alert { container[SwiftTextMarkdownAttributes.Alert.self] = alert }
		if let definition = context.footnoteDefinition {
			container[SwiftTextMarkdownAttributes.FootnoteDefinition.self] = definition
		}
		if let footnoteReference { container[SwiftTextMarkdownAttributes.FootnoteReference.self] = footnoteReference }
		if let imageSource { container[SwiftTextMarkdownAttributes.ImageSource.self] = imageSource }
		result.append(AttributedString(text, attributes: container))
	}

	private func reverseSmart(_ string: String) -> String {
		preserveSmartPunctuation ? string : reverseSmartPunctuation(string)
	}

	/// Foundation uses U+2E3B (THREE-EM DASH) as a thematic-break placeholder.
	private var thematicBreakText: String { "\u{2E3B}" }

	// MARK: Alert detection (ports SwiftMarkdownHTMLRenderer's logic)

	private func detectAlert(in quote: BlockQuote) -> (kind: MarkdownAlert, terminator: Character)? {
		if let token = bracketedAlertToken(in: quote), let kind = MarkdownAlert(token: token) {
			return (kind, "]")
		}
		if let token = doccAsideToken(in: quote), let kind = MarkdownAlert(token: token) {
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
			if let next = inlines.first, next is SoftBreak { inlines.removeFirst() }
		} else {
			inlines[0] = Text(stripped)
		}
		return inlines
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
