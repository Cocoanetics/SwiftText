import Foundation
import Markdown
import SwiftTextMarkdown

/// Markdown → Foundation `AttributedString` renderer built on swift-markdown's AST.
///
/// The output mirrors the structure Foundation's own `AttributedString(markdown:)`
/// produces — block hierarchy, inline styling, links — but works on **every**
/// platform Foundation ships on, including Linux and Windows.
///
/// Foundation's `PresentationIntent` / `InlinePresentationIntent` live in Apple's
/// SDK Foundation and are absent from cross-platform swift-foundation, so the
/// renderer always carries the structure in portable custom attributes
/// (``MarkdownBlock`` via ``SwiftTextMarkdownAttributes/Block`` and
/// ``MarkdownInlineStyle`` via ``SwiftTextMarkdownAttributes/InlineStyle``) and,
/// **additionally on Apple platforms**, sets the native `presentationIntent` /
/// `inlinePresentationIntent` derived from the same data so the result
/// interoperates with SwiftUI / TextKit. Blocks are delimited by distinct
/// intent identities (a shared pre-order counter), with no literal newlines
/// between them — exactly as Foundation does.
///
/// Unlike Foundation's built-in parser, it uses swift-markdown (the same AST as
/// the package's HTML/DOCX/Pages paths), so it covers the full GFM superset:
/// tables with alignment, strikethrough, task lists, and — via the custom scope
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

		// Then definitions, in the SAME builder so block identities stay globally
		// unique. Re-scan until a pass renders nothing new, so a definition
		// referenced only from another definition still resolves.
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
	/// (full GFM + footnotes + alerts, all-platform), as opposed to Foundation's
	/// built-in `init(markdown:)`.
	public init(
		swiftTextMarkdown markdown: String,
		options: MarkdownAttributedStringRenderer.Options = []
	) {
		self = MarkdownAttributedStringRenderer.convert(markdown, options: options)
	}
}

// MARK: - Emit context

/// State threaded down the block tree: the enclosing block components (the
/// ancestor chain for the next leaf, innermost first), and the alert /
/// footnote-definition tags applied to runs.
private struct EmitContext {
	var ancestors: [MarkdownBlock.Component] = []
	var alert: MarkdownAlert?
	var footnoteDefinition: Int?

	/// Returns a context with `component` pushed as the new innermost ancestor.
	func nested(_ component: MarkdownBlock.Component) -> EmitContext {
		var copy = self
		copy.ancestors.insert(component, at: 0)
		return copy
	}
}

/// The inline styling accumulated while descending inline nodes.
private struct InlineStyleAccumulator {
	var style: MarkdownInlineStyle = []
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
	private func component(_ kind: MarkdownBlock.Kind) -> MarkdownBlock.Component {
		defer { nextIdentity += 1 }
		return MarkdownBlock.Component(kind, identity: nextIdentity)
	}

	// MARK: Block emission

	func emitBlocks(_ children: some Sequence<Markup>, _ context: EmitContext) {
		for child in children { emitBlock(child, context) }
	}

	private func emitBlock(_ markup: Markup, _ context: EmitContext) {
		switch markup {
		case let paragraph as Paragraph:
			emitInlines(paragraph.children, block: leaf(.paragraph, context), context)
		case let heading as Heading:
			let level = max(1, min(heading.level, 6))
			emitInlines(heading.children, block: leaf(.header(level: level), context), context)
		case let codeBlock as CodeBlock:
			// Foundation keeps the code's trailing newline; mirror that.
			append(codeBlock.code, block: leaf(.codeBlock(languageHint: codeBlock.language), context), style: [], context)
		case is ThematicBreak:
			append(thematicBreakText, block: leaf(.thematicBreak, context), style: [], context)
		case let htmlBlock as HTMLBlock:
			// Foundation gives HTML blocks no block intent + a `.blockHTML` trait.
			append(htmlBlock.rawHTML, block: nil, style: .blockHTML, context)
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

	/// Builds the full leaf component chain (leaf first) for a leaf block.
	private func leaf(_ kind: MarkdownBlock.Kind, _ context: EmitContext) -> [MarkdownBlock.Component] {
		[component(kind)] + context.ancestors
	}

	// MARK: Blockquotes & alerts

	private func emitBlockQuote(_ blockQuote: BlockQuote, _ context: EmitContext) {
		let quoteComponent = component(.blockQuote)
		let quoteContext = context.nested(quoteComponent)

		if let detected = detectAlert(in: blockQuote) {
			var alertContext = quoteContext
			alertContext.alert = detected.kind
			let children = Array(blockQuote.children)
			for (index, child) in children.enumerated() {
				if index == 0, let paragraph = child as? Paragraph {
					let inlines = strippedAlertMarker(in: paragraph, terminator: detected.terminator)
					guard !inlines.isEmpty else { continue }
					emitInlines(inlines, block: [component(.paragraph)] + alertContext.ancestors, alertContext)
				} else {
					emitBlock(child, alertContext)
				}
			}
			return
		}

		emitBlocks(blockQuote.children, quoteContext)
	}

	// MARK: Lists

	private func emitList(_ list: ListItemContainer, ordered: Bool, _ context: EmitContext) {
		let listContext = context.nested(component(ordered ? .orderedList : .unorderedList))
		var ordinal = ordered ? orderedListStart(list) : 1
		for case let item as ListItem in list.children {
			let itemContext = listContext.nested(component(.listItem(ordinal: ordinal)))
			emitBlocks(item.children, itemContext)
			ordinal += 1
		}
	}

	private func orderedListStart(_ list: ListItemContainer) -> Int {
		(list as? OrderedList).map { Int($0.startIndex) } ?? 1
	}

	// MARK: Tables

	private func emitTable(_ table: Table, _ context: EmitContext) {
		let columns = table.columnAlignments.map { alignment -> MarkdownBlock.ColumnAlignment in
			switch alignment {
			case .center: return .center
			case .right: return .right
			case .left, .none: return .left
			}
		}
		let tableContext = context.nested(component(.table(columns: columns)))

		let headerContext = tableContext.nested(component(.tableHeaderRow))
		for (column, cell) in table.head.cells.enumerated() {
			emitInlines(cell.children, block: [component(.tableCell(columnIndex: column))] + headerContext.ancestors, headerContext)
		}

		var rowIndex = 1
		for row in table.body.rows {
			let rowContext = tableContext.nested(component(.tableRow(rowIndex: rowIndex)))
			for (column, cell) in row.cells.enumerated() {
				emitInlines(cell.children, block: [component(.tableCell(columnIndex: column))] + rowContext.ancestors, rowContext)
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
			append("\(number). ", block: leaf(.paragraph, context), style: .stronglyEmphasized, context)
			return
		}

		for (index, block) in blocks.enumerated() {
			if index == 0, let paragraph = block as? Paragraph {
				let leafBlock = leaf(.paragraph, context)
				append("\(number). ", block: leafBlock, style: .stronglyEmphasized, context)
				emitInlines(paragraph.children, block: leafBlock, context)
			} else {
				emitBlock(block, context)
			}
		}
	}

	// MARK: Inline emission

	private func emitInlines(
		_ inlines: some Sequence<Markup>, block: [MarkdownBlock.Component]?, _ context: EmitContext
	) {
		for inline in inlines {
			emitInline(inline, InlineStyleAccumulator(), block: block, context)
		}
	}

	private func emitInline(
		_ markup: Markup, _ accumulator: InlineStyleAccumulator,
		block: [MarkdownBlock.Component]?, _ context: EmitContext
	) {
		switch markup {
		case let text as Text:
			emitText(text.string, accumulator, block: block, context)
		case let emphasis as Emphasis:
			descend(emphasis, inserting: .emphasized, accumulator, block: block, context)
		case let strong as Strong:
			descend(strong, inserting: .stronglyEmphasized, accumulator, block: block, context)
		case let strikethrough as Strikethrough:
			descend(strikethrough, inserting: .strikethrough, accumulator, block: block, context)
		case let inlineCode as InlineCode:
			var style = accumulator.style
			style.insert(.code)
			append(inlineCode.code, block: block, style: style, link: accumulator.link, context)
		case let link as Link:
			var nested = accumulator
			nested.link = (link.destination).flatMap(URL.init(string:)) ?? accumulator.link
			for child in link.children { emitInline(child, nested, block: block, context) }
		case let image as Image:
			let alt = reverseSmart(swiftMarkdownPlainText(of: image))
			append(alt, block: block, style: accumulator.style, link: accumulator.link, context, imageSource: image.source)
		case let inlineHTML as InlineHTML:
			var style = accumulator.style
			style.insert(.inlineHTML)
			append(inlineHTML.rawHTML, block: block, style: style, link: accumulator.link, context)
		case is SoftBreak:
			var style = accumulator.style
			style.insert(.softBreak)
			append(" ", block: block, style: style, link: accumulator.link, context)
		case is LineBreak:
			var style = accumulator.style
			style.insert(.lineBreak)
			append("\n", block: block, style: style, link: accumulator.link, context)
		default:
			for child in markup.children { emitInline(child, accumulator, block: block, context) }
		}
	}

	private func descend(
		_ markup: Markup, inserting trait: MarkdownInlineStyle,
		_ accumulator: InlineStyleAccumulator, block: [MarkdownBlock.Component]?, _ context: EmitContext
	) {
		var nested = accumulator
		nested.style.insert(trait)
		for child in markup.children { emitInline(child, nested, block: block, context) }
	}

	/// Emits a `Text` node, splitting `[^id]` references (when a resolver is
	/// active) into footnote-reference runs tagged with their number.
	private func emitText(
		_ string: String, _ accumulator: InlineStyleAccumulator,
		block: [MarkdownBlock.Component]?, _ context: EmitContext
	) {
		guard let resolver else {
			append(reverseSmart(string), block: block, style: accumulator.style, link: accumulator.link, context)
			return
		}
		for segment in resolver.resolve(string) {
			switch segment {
			case .text(let value):
				append(reverseSmart(value), block: block, style: accumulator.style, link: accumulator.link, context)
			case .reference(let number):
				append("\(number)", block: block, style: accumulator.style, link: accumulator.link, context, footnoteReference: number)
			}
		}
	}

	// MARK: Append

	private func append(
		_ text: String,
		block: [MarkdownBlock.Component]?,
		style: MarkdownInlineStyle,
		link: URL? = nil,
		_ context: EmitContext,
		footnoteReference: Int? = nil,
		imageSource: String? = nil
	) {
		guard !text.isEmpty else { return }
		var container = AttributeContainer()

		// Portable custom attributes — set on every platform.
		if let block { container[SwiftTextMarkdownAttributes.Block.self] = MarkdownBlock(components: block) }
		if !style.isEmpty { container[SwiftTextMarkdownAttributes.InlineStyle.self] = style }
		if let link { container.link = link }
		if let alert = context.alert { container[SwiftTextMarkdownAttributes.Alert.self] = alert }
		if let definition = context.footnoteDefinition {
			container[SwiftTextMarkdownAttributes.FootnoteDefinition.self] = definition
		}
		if let footnoteReference { container[SwiftTextMarkdownAttributes.FootnoteReference.self] = footnoteReference }
		if let imageSource { container[SwiftTextMarkdownAttributes.ImageSource.self] = imageSource }

		// Native Foundation intents — Apple platforms only (absent on Linux/Windows).
		#if canImport(Darwin)
		if let block { container.presentationIntent = Builder.nativePresentationIntent(block) }
		if let native = Builder.nativeInlinePresentationIntent(style) { container.inlinePresentationIntent = native }
		#endif

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

// MARK: - Native intent bridging (Apple platforms only)

#if canImport(Darwin)
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension Builder {

	/// Rebuilds a native `PresentationIntent` from the portable component chain
	/// (innermost first → built outermost first via the parent chain).
	static func nativePresentationIntent(_ components: [MarkdownBlock.Component]) -> PresentationIntent {
		var parent: PresentationIntent?
		for component in components.reversed() {
			parent = PresentationIntent(nativeKind(component.kind), identity: component.identity, parent: parent)
		}
		// `components` is always non-empty for a leaf block.
		return parent ?? PresentationIntent(.paragraph, identity: 0, parent: nil)
	}

	private static func nativeKind(_ kind: MarkdownBlock.Kind) -> PresentationIntent.Kind {
		switch kind {
		case .paragraph: return .paragraph
		case .header(let level): return .header(level: level)
		case .orderedList: return .orderedList
		case .unorderedList: return .unorderedList
		case .listItem(let ordinal): return .listItem(ordinal: ordinal)
		case .codeBlock(let hint): return .codeBlock(languageHint: hint)
		case .blockQuote: return .blockQuote
		case .thematicBreak: return .thematicBreak
		case .table(let columns):
			return .table(columns: columns.map { PresentationIntent.TableColumn(alignment: nativeAlignment($0)) })
		case .tableHeaderRow: return .tableHeaderRow
		case .tableRow(let rowIndex): return .tableRow(rowIndex: rowIndex)
		case .tableCell(let columnIndex): return .tableCell(columnIndex: columnIndex)
		}
	}

	private static func nativeAlignment(_ alignment: MarkdownBlock.ColumnAlignment) -> PresentationIntent.TableColumn.Alignment {
		switch alignment {
		case .left: return .left
		case .center: return .center
		case .right: return .right
		}
	}

	static func nativeInlinePresentationIntent(_ style: MarkdownInlineStyle) -> InlinePresentationIntent? {
		var result: InlinePresentationIntent = []
		if style.contains(.emphasized) { result.insert(.emphasized) }
		if style.contains(.stronglyEmphasized) { result.insert(.stronglyEmphasized) }
		if style.contains(.code) { result.insert(.code) }
		if style.contains(.strikethrough) { result.insert(.strikethrough) }
		if style.contains(.softBreak) { result.insert(.softBreak) }
		if style.contains(.lineBreak) { result.insert(.lineBreak) }
		if style.contains(.inlineHTML) { result.insert(.inlineHTML) }
		if style.contains(.blockHTML) { result.insert(.blockHTML) }
		return result.isEmpty ? nil : result
	}
}
#endif

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
