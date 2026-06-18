import Foundation
import Markdown

/// Converts the libxml2-backed DOM tree into a swift-markdown `Document`, which
/// is then rendered to Markdown text by swift-markdown's `MarkupFormatter`.
///
/// This replaces the previous hand-rolled DOM→string renderer: instead of
/// concatenating Markdown syntax directly, we build a typed AST (a `Document`
/// of `BlockMarkup`/`InlineMarkup`) and let `Document.format(options:)` own all
/// the fiddly output concerns — paragraph spacing, list numbering, table column
/// padding, blockquote prefixing, and nested-structure indentation.
///
/// The DOM-specific decisions that swift-markdown has no concept of stay here:
/// element skipping (`script`/`style`/…), transparent-wrapper unwrapping (the
/// deep div/span towers in HTML email), the layout-vs-data table heuristic,
/// fragment-only links rendered as plain text, and image source resolution.
///
/// ## Block / inline impedance
/// HTML mixes block and inline content freely; the Markdown AST is strictly
/// typed (a `Paragraph` holds only inlines, a `BlockQuote` only blocks). The
/// converter bridges this by buffering loose inline content inside any block
/// container and flushing it into an implicit `Paragraph` whenever a block-level
/// child appears (see ``blockChildren(of:)``).
struct DOMMarkupConverter {
	let imageResolver: ((String) -> String?)?

	/// Footnote restoration index, or `nil` when the document has no detectable
	/// footnotes (in which case the converter behaves exactly as before).
	var footnotes: DOMFootnoteIndex?

	/// Formatting options for `MarkupFormatter`. Most defaults already match the
	/// previous renderer (`-` bullets, `*`/`**` emphasis, fenced code blocks,
	/// ATX `#` headings); we additionally request incrementing ordered-list
	/// numerals (`1.`, `2.`, …) instead of swift-markdown's default `.allSame(1)`
	/// so numbered lists read conventionally and match the old output.
	///
	/// Computed (not stored) because `MarkupFormatter.Options` isn't `Sendable`,
	/// so a `static let` would violate Swift 6 global-state concurrency checks.
	///
	/// Known limitation: swift-markdown's `MarkupFormatter` only indents a nested
	/// list when it shares the parent list's type (its `linePrefix` keys off a
	/// per-type counter), so e.g. an `<ol>` nested in a `<ul>` renders flush-left.
	/// The structure is preserved in the AST; only the rendered indentation is
	/// affected. This is still an improvement on the previous renderer, which
	/// concatenated nested list text onto the parent item with no break at all.
	///
	/// Upstream fix: https://github.com/swiftlang/swift-markdown/pull/216 (open and
	/// unmerged as of swift-markdown 0.8.0). If/when it ships, mixed-type nesting
	/// will indent on its own — update `mixedTypeNestedListIsNotIndentedByFormatter`.
	static var formatOptions: MarkupFormatter.Options {
		MarkupFormatter.Options(
			unorderedListMarker: .dash,
			orderedListNumerals: .incrementing(start: 1),
			useCodeFence: .always,
			emphasisMarker: .star,
			preferredHeadingStyle: .atx
		)
	}

	/// Renders `element` and its subtree to a Markdown string. Entry point used
	/// by ``DOMElement/markdown(imageResolver:)``.
	static func markdown(from element: DOMElement, imageResolver: ((String) -> String?)?) -> String {
		let footnotes = DOMFootnoteIndex.build(from: element)
		let converter = DOMMarkupConverter(imageResolver: imageResolver, footnotes: footnotes)
		return converter.document(from: element).format(options: formatOptions)
	}

	/// Builds the swift-markdown `Document` for `root`'s children, appending any
	/// restored footnote definitions after the body.
	func document(from root: DOMElement) -> Document {
		var blocks = blockChildren(of: root)
		if let footnotes {
			for definition in footnotes.orderedDefinitions {
				blocks.append(footnoteDefinitionBlock(label: definition.label, body: definition.body))
			}
		}
		return Document(blocks)
	}

	// MARK: - Tag classification

	/// Tags whose entire subtree is dropped from Markdown output.
	private static let skippedTags: Set<String> = [
		"script", "style", "iframe", "nav", "meta", "link", "title",
		"select", "input", "button", "noscript", "footer", "head"
	]

	/// Tags treated as block-level for the inline-buffering decision. Anything
	/// not here (and not a skipped tag) is treated as inline.
	private static let blockTags: Set<String> = [
		"html", "body", "main", "article", "section", "header", "aside",
		"div", "p", "figure", "figcaption",
		"h1", "h2", "h3", "h4", "h5", "h6",
		"ul", "ol", "li", "dl", "dd", "dt",
		"blockquote", "pre", "table", "hr"
	]

	private func isBlockLevel(_ node: DOMNode) -> Bool {
		guard let element = node as? DOMElement else { return false }
		// Skipped tags are non-rendering, NOT block-level: treating them as block
		// would flush the inline buffer and split the surrounding paragraph (e.g.
		// `<p>Hello<script>…</script>world</p>` must stay one paragraph). Both
		// blockMarkup and inlineMarkup already drop skipped tags to nothing, so
		// classifying them as inline simply omits the subtree without a break.
		return Self.blockTags.contains(element.name.lowercased())
	}

	// MARK: - Block context

	/// Converts the children of a block container into a list of blocks,
	/// buffering loose inline content into implicit paragraphs.
	private func blockChildren(of element: DOMElement) -> [BlockMarkup] {
		var blocks: [BlockMarkup] = []
		var inlineBuffer: [InlineMarkup] = []

		func flush() {
			let trimmed = trimInlines(inlineBuffer)
			inlineBuffer.removeAll()
			guard !trimmed.isEmpty else { return }
			blocks.append(Paragraph(trimmed))
		}

		for child in element.children {
			// Footnote definition containers are rendered separately (appended as
			// `[^id]: …` blocks), so skip them in the normal block flow.
			if let childElement = child as? DOMElement,
			   footnotes?.skip.contains(ObjectIdentifier(childElement)) == true {
				continue
			}
			if isBlockLevel(child) {
				flush()
				blocks.append(contentsOf: blockMarkup(from: child))
			} else {
				inlineBuffer.append(contentsOf: inlineMarkup(from: child))
			}
		}
		flush()
		return blocks
	}

	/// Converts a single block-level DOM element into zero or more blocks.
	private func blockMarkup(from node: DOMNode) -> [BlockMarkup] {
		guard let original = node as? DOMElement else { return [] }
		if Self.skippedTags.contains(original.name.lowercased()) { return [] }

		// Collapse single-child transparent wrapper chains (e.g. deeply nested
		// div/span towers) iteratively to avoid pathological recursion depth.
		let element = unwrapTransparent(original)
		let name = element.name.lowercased()

		switch name {
		case "h1", "h2", "h3", "h4", "h5", "h6":
			let level = Int(name.dropFirst()) ?? 1
			let inlines = trimInlines(inlineChildren(of: element))
			return inlines.isEmpty ? [] : [Heading(level: level, inlines)]

		case "ul":
			let items = listItems(of: element)
			return items.isEmpty ? [] : [UnorderedList(items)]

		case "ol":
			let items = listItems(of: element)
			return items.isEmpty ? [] : [OrderedList(items)]

		case "blockquote":
			let inner = blockChildren(of: element)
			return inner.isEmpty ? [] : [BlockQuote(inner)]

		case "pre":
			return [codeBlock(from: element)]

		case "hr":
			return [ThematicBreak()]

		case "table":
			return tableBlocks(from: element)

		case "figcaption":
			let inlines = trimInlines(inlineChildren(of: element))
			return inlines.isEmpty ? [] : [Paragraph(inlines)]

		default:
			// Transparent block container: html/body/div/p/section/li/figure/…
			// Recurse, buffering loose inline content into paragraphs.
			return blockChildren(of: element)
		}
	}

	// MARK: - Inline context

	private func inlineChildren(of element: DOMElement) -> [InlineMarkup] {
		element.children.flatMap { inlineMarkup(from: $0) }
	}

	/// Converts a single DOM node into zero or more inline markups.
	private func inlineMarkup(from node: DOMNode) -> [InlineMarkup] {
		if let text = node as? DOMText {
			let string = collapsedText(text)
			return string.isEmpty ? [] : [Text(string)]
		}

		guard let original = node as? DOMElement else { return [] }
		if Self.skippedTags.contains(original.name.lowercased()) { return [] }

		let element = unwrapTransparent(original)
		let name = element.name.lowercased()

		switch name {
		case "b", "strong":
			return wrapInline(inlineChildren(of: element)) { Strong($0) }

		case "i", "em":
			return wrapInline(inlineChildren(of: element)) { Emphasis($0) }

		case "del", "s", "strike":
			return wrapInline(inlineChildren(of: element)) { Strikethrough($0) }

		case "code":
			let code = rawText(of: element)
			return code.isEmpty ? [] : [InlineCode(code)]

		case "br":
			return [LineBreak()]

		case "a":
			return anchorInlines(element)

		case "img":
			return imageInlines(element)

		default:
			// Inline-transparent (span/font/sup/sub/…) and anything else: recurse.
			return inlineChildren(of: element)
		}
	}

	/// Wraps inline children in an emphasis-style container, externalizing any
	/// leading/trailing whitespace so the markers hug the content. CommonMark
	/// rejects `** bold **` as emphasis, so ` ` must sit outside the markers.
	private func wrapInline(_ children: [InlineMarkup], _ make: ([InlineMarkup]) -> InlineMarkup) -> [InlineMarkup] {
		let (leading, core, trailing) = splitOuterWhitespace(children)
		guard !core.isEmpty else { return leading + trailing }
		return leading + [make(core)] + trailing
	}

	/// Splits a single leading/trailing space out of the boundary `Text` leaves
	/// (text whitespace is already collapsed to single spaces by ``collapsedText``).
	private func splitOuterWhitespace(
		_ children: [InlineMarkup]
	) -> (leading: [InlineMarkup], core: [InlineMarkup], trailing: [InlineMarkup]) {
		var core = children
		var leading: [InlineMarkup] = []
		var trailing: [InlineMarkup] = []

		if let first = core.first as? Text {
			let stripped = String(first.string.drop { $0 == " " })
			if stripped.count != first.string.count {
				leading = [Text(" ")]
				if stripped.isEmpty { core.removeFirst() } else { core[0] = Text(stripped) }
			}
		}
		if let last = core.last as? Text {
			let stripped = String(last.string.reversed().drop { $0 == " " }.reversed())
			if stripped.count != last.string.count {
				trailing = [Text(" ")]
				if stripped.isEmpty { core.removeLast() } else { core[core.count - 1] = Text(stripped) }
			}
		}
		return (leading, core, trailing)
	}

	private func anchorInlines(_ element: DOMElement) -> [InlineMarkup] {
		let href = (element.attributes["href"] as? String) ?? ""

		// Footnote restoration: a reference whose target is a known definition
		// becomes `[^label]`; a backref (link to a reference's own id) is dropped
		// so it doesn't litter the definition body.
		if let footnotes, let fragment = URLComponents(string: href)?.fragment {
			if let label = footnotes.labelForID[fragment] {
				return [Text("[^\(label)]")]
			}
			if footnotes.refIDs.contains(fragment) {
				return []
			}
		}

		let content = trimInlines(inlineChildren(of: element))

		// Fragment links (in-page anchors, or any URL carrying a #fragment) are
		// rendered as plain text — matches the previous renderer's behavior.
		if href.contains("#"),
		   let components = URLComponents(string: href),
		   components.fragment != nil {
			return content
		}

		guard !href.isEmpty, !content.isEmpty else {
			return content
		}
		return [makeLink(destination: href, children: content)]
	}

	/// `Link`'s typed initializer only accepts `RecurringInlineMarkup` children,
	/// which excludes `Image` — so a linked image (`<a><img></a>`) can't go
	/// through it. `withUncheckedChildren` lets arbitrary inline content survive.
	private func makeLink(destination: String, children: [InlineMarkup]) -> InlineMarkup {
		let markupChildren = children.map { $0 as Markup }
		// withUncheckedChildren erases the type to `Markup`; the input was a Link,
		// so casting back is sound.
		// swiftlint:disable:next force_cast
		return Link(destination: destination).withUncheckedChildren(markupChildren) as! Link
	}

	private func imageInlines(_ element: DOMElement) -> [InlineMarkup] {
		let source = (element.attributes["src"] as? String) ?? ""
		let resolved = imageResolver?(source) ?? source
		guard !resolved.isEmpty, !resolved.hasPrefix("data:") else { return [] }

		let alt = (element.attributes["alt"] as? String) ?? "Image"
		if alt.isEmpty {
			return [Image(source: resolved)]
		}
		return [Image(source: resolved, Text(alt))]
	}

	// MARK: - Footnotes

	/// Builds a `[^label]: …` definition paragraph from a footnote definition's
	/// DOM body, stripping any echoed leading marker (e.g. a project-style
	/// `[1]:`) and trailing backref glyph (`↩`). Backref *links* are already
	/// dropped in ``anchorInlines(_:)`` via the reference-id set.
	private func footnoteDefinitionBlock(label: String, body: DOMElement) -> BlockMarkup {
		var inlines = trimInlines(inlineChildren(of: body))
		inlines = stripLeadingMarker(inlines, label: label)
		inlines = stripTrailingBackref(inlines)
		inlines = trimInlines(inlines)
		let prefix = inlines.isEmpty ? "[^\(label)]:" : "[^\(label)]: "
		return Paragraph([Text(prefix)] + inlines)
	}

	private func stripLeadingMarker(_ inlines: [InlineMarkup], label: String) -> [InlineMarkup] {
		guard let first = inlines.first else { return inlines }
		let lead = plainText(of: first).trimmingCharacters(in: .whitespaces)
		if DOMFootnoteIndex.isMarkerToken(lead, label: label) {
			return Array(inlines.dropFirst())
		}
		if let text = first as? Text, let rest = DOMFootnoteIndex.strippedMarkerPrefix(text.string, label: label) {
			var copy = inlines
			if rest.isEmpty { copy.removeFirst() } else { copy[0] = Text(rest) }
			return copy
		}
		return inlines
	}

	private func stripTrailingBackref(_ inlines: [InlineMarkup]) -> [InlineMarkup] {
		var result = inlines
		while let last = result.last as? Text, DOMFootnoteIndex.isBackrefGlyph(last.string) {
			result.removeLast()
		}
		return result
	}

	private func plainText(of markup: Markup) -> String {
		if let text = markup as? Text { return text.string }
		if let code = markup as? InlineCode { return code.code }
		return markup.children.map { plainText(of: $0) }.joined()
	}

	// MARK: - Lists

	private func listItems(of element: DOMElement) -> [ListItem] {
		var items: [ListItem] = []
		for child in element.children {
			guard let li = child as? DOMElement, li.name.lowercased() == "li" else { continue }
			let blocks = blockChildren(of: li)
			guard !blocks.isEmpty else { continue }
			items.append(ListItem(blocks))
		}
		return items
	}

	// MARK: - Code

	private func codeBlock(from element: DOMElement) -> CodeBlock {
		// `<pre><code>…</code></pre>` is the common shape; unwrap the lone <code>.
		let source: DOMElement
		if element.children.count == 1,
		   let code = element.children.first as? DOMElement,
		   code.name.lowercased() == "code" {
			source = code
		} else {
			source = element
		}
		let text = rawText(of: source).trimmingCharacters(in: .newlines)
		return CodeBlock(language: nil, text)
	}

	/// Concatenates the raw (whitespace-preserving) text of an element subtree.
	/// Used for code blocks and inline code, where collapsing must not happen.
	private func rawText(of element: DOMElement) -> String {
		var result = ""
		appendRawText(of: element, into: &result)
		return result
	}

	private func appendRawText(of node: DOMNode, into result: inout String) {
		if let text = node as? DOMText {
			result += text.textValue
			return
		}
		guard let element = node as? DOMElement else { return }
		if element.name.lowercased() == "br" {
			result += "\n"
			return
		}
		for child in element.children {
			appendRawText(of: child, into: &result)
		}
	}

	// MARK: - Text

	/// Collapses HTML whitespace the way the browser would: runs of whitespace
	/// become a single space, with a single leading/trailing space preserved so
	/// inline boundaries keep their separation. Whitespace-only nodes collapse to
	/// a single separating space.
	private func collapsedText(_ text: DOMText) -> String {
		if text.preserveWhitespace { return text.textValue }

		let value = text.textValue
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty {
			return value.isEmpty ? "" : " "
		}

		let collapsed = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
		let leading = (value.first?.isWhitespace == true) ? " " : ""
		let trailing = (value.last?.isWhitespace == true) ? " " : ""
		return leading + collapsed + trailing
	}

	/// Trims leading/trailing whitespace-only inlines (and stray breaks) from a
	/// paragraph/heading/cell's content, and strips spaces hanging off the
	/// boundary `Text` leaves.
	private func trimInlines(_ inlines: [InlineMarkup]) -> [InlineMarkup] {
		var result = inlines

		while let first = result.first {
			if first is SoftBreak || first is LineBreak { result.removeFirst(); continue }
			if let text = first as? Text {
				let stripped = String(text.string.drop { $0 == " " || $0 == "\n" })
				if stripped.isEmpty { result.removeFirst(); continue }
				if stripped.count != text.string.count { result[0] = Text(stripped) }
			}
			break
		}

		while let last = result.last {
			if last is SoftBreak || last is LineBreak { result.removeLast(); continue }
			if let text = last as? Text {
				let stripped = String(text.string.reversed().drop { $0 == " " || $0 == "\n" }.reversed())
				if stripped.isEmpty { result.removeLast(); continue }
				if stripped.count != text.string.count { result[result.count - 1] = Text(stripped) }
			}
			break
		}

		return result
	}

	// MARK: - Tables

	private func tableBlocks(from element: DOMElement) -> [BlockMarkup] {
		if isLayoutTable(element) {
			return layoutTableBlocks(from: element)
		}

		let rows = collectTableRows(from: element)
		guard let headerRow = rows.first else { return [] }

		let headerCells = tableCellElements(in: headerRow)
		let bodyRows = Array(rows.dropFirst())
		let columnCount = max(
			headerCells.count,
			bodyRows.map { tableCellElements(in: $0).count }.max() ?? 0
		)
		guard columnCount > 0 else { return [] }

		let head = Table.Head(makeCells(headerCells, columnCount: columnCount))
		let body = Table.Body(bodyRows.map { row in
			Table.Row(makeCells(tableCellElements(in: row), columnCount: columnCount))
		})
		let alignments = [Table.ColumnAlignment?](repeating: nil, count: columnCount)
		return [Table(columnAlignments: alignments, header: head, body: body)]
	}

	private func makeCells(_ cells: [DOMElement], columnCount: Int) -> [Table.Cell] {
		var result = cells.map { Table.Cell(trimInlines(inlineChildren(of: $0))) }
		while result.count < columnCount {
			result.append(Table.Cell([] as [InlineMarkup]))
		}
		return result
	}

	/// Layout tables don't map to a Markdown table. A row whose cells hold only
	/// inline content is joined into a single space-separated paragraph (matching
	/// the previous renderer's `A B` output for label/value or icon/text pairs);
	/// rows with block-level cell content fall back to emitting those blocks
	/// directly. Either way no pipe table is produced.
	private func layoutTableBlocks(from element: DOMElement) -> [BlockMarkup] {
		let rows = collectTableRows(from: element)
		var blocks: [BlockMarkup] = []
		for row in rows {
			let cells = tableCellElements(in: row)
			if cells.contains(where: cellContainsBlock) {
				for cell in cells {
					blocks.append(contentsOf: blockChildren(of: cell))
				}
			} else {
				var inlines: [InlineMarkup] = []
				for cell in cells {
					let cellInlines = trimInlines(inlineChildren(of: cell))
					guard !cellInlines.isEmpty else { continue }
					if !inlines.isEmpty { inlines.append(Text(" ")) }
					inlines.append(contentsOf: cellInlines)
				}
				let trimmed = trimInlines(inlines)
				if !trimmed.isEmpty { blocks.append(Paragraph(trimmed)) }
			}
		}
		return blocks.isEmpty ? blockChildren(of: element) : blocks
	}

	private func cellContainsBlock(_ cell: DOMElement) -> Bool {
		cell.children.contains { isBlockLevel($0) }
	}

	private func collectTableRows(from element: DOMElement) -> [DOMElement] {
		var rows: [DOMElement] = []
		for child in element.children {
			guard let childElement = child as? DOMElement else { continue }
			switch childElement.name.lowercased() {
			case "tr":
				rows.append(childElement)
			case "thead", "tbody", "tfoot":
				rows.append(contentsOf: collectTableRows(from: childElement))
			default:
				break
			}
		}
		return rows
	}

	private func tableCellElements(in row: DOMElement) -> [DOMElement] {
		row.children
			.compactMap { $0 as? DOMElement }
			.filter { ["td", "th"].contains($0.name.lowercased()) }
	}

	private func hasNestedTable(in element: DOMElement) -> Bool {
		for child in element.children {
			guard let el = child as? DOMElement else { continue }
			let name = el.name.lowercased()
			if name == "table" { return true }
			if ["tr", "td", "th", "thead", "tbody", "tfoot"].contains(name), hasNestedTable(in: el) {
				return true
			}
		}
		return false
	}

	/// Heuristic distinguishing data tables (→ Markdown table) from layout tables
	/// (→ flattened content). Ported from the previous renderer.
	private func isLayoutTable(_ element: DOMElement) -> Bool {
		if hasNestedTable(in: element) { return true }

		let rows = collectTableRows(from: element)
		if rows.count <= 1 { return true }

		let firstRowCells = tableCellElements(in: rows[0]).count
		if firstRowCells <= 1 { return true }

		var totalCells = 0
		var imageCells = 0
		var blockCells = 0
		let blockElementNames: Set<String> = ["p", "div", "table", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6"]

		for row in rows {
			for cell in tableCellElements(in: row) {
				totalCells += 1
				let childElements = cell.children.compactMap { $0 as? DOMElement }
				if childElements.count == 1, childElements[0].name.lowercased() == "img" {
					imageCells += 1
				}
				let blockCount = childElements.filter { blockElementNames.contains($0.name.lowercased()) }.count
				if blockCount >= 3 { blockCells += 1 }
			}
		}

		if totalCells > 0 {
			let imageRatio = Double(imageCells) / Double(totalCells)
			let blockRatio = Double(blockCells) / Double(totalCells)
			if imageRatio > 0.5 || blockRatio > 0.3 { return true }
		}

		let cellCounts = rows.map { tableCellElements(in: $0).count }
		if cellCounts.isEmpty { return true }

		let average = Double(cellCounts.reduce(0, +)) / Double(cellCounts.count)
		let variance = cellCounts.map { Double($0) - average }.map { $0 * $0 }.reduce(0, +) / Double(cellCounts.count)
		if sqrt(variance) > 1.0 { return true }

		return false
	}

	// MARK: - Transparent wrappers

	/// Iteratively descends single-child transparent-wrapper chains (deeply
	/// nested div/span/font towers from HTML email) to avoid stack-overflow-depth
	/// recursion. Stops at the innermost wrapper whose child isn't another
	/// transparent wrapper.
	private func unwrapTransparent(_ element: DOMElement) -> DOMElement {
		guard element.isTransparentWrapper else { return element }
		var current = element
		var steps = 0
		while steps < 10_000,
			  current.isTransparentWrapper,
			  current.children.count == 1,
			  let only = current.children.first as? DOMElement,
			  only.isTransparentWrapper {
			current = only
			steps += 1
		}
		return current
	}
}
