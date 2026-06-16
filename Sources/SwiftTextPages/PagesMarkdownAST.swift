import Foundation
import Markdown

/// Builds a swift-markdown `Document` (the Markdown AST) from the structure a
/// `.pages` file decoded into `PagesDocument`. This is the exact inverse of
/// `MarkdownToPages`, which walks a swift-markdown `Document` to *generate* Pages —
/// so reading and writing pivot on the same AST.
///
/// Producing an AST (rather than a string) is what makes `pages → md` robust: cmark's
/// `MarkupFormatter` handles pipe escaping in table cells, list nesting, heading shape
/// and inline wrapping, instead of ad-hoc string assembly. It also lets a `.pages`
/// document feed any other AST consumer in the package (the HTML renderer, the DOCX
/// builder, structural diffing), the same way `DocumentBlockMarkdownRenderer` does for
/// OCR output.
extension PagesDocument {
	/// The document as a swift-markdown AST.
	public func markdownDocument() -> Document {
		let bodySize = dominantBodyFontSize()
		var blocks = [BlockMarkup]()
		var index = 0

		while index < paragraphs.count {
			let paragraph = paragraphs[index]

			// Native tables anchored in this paragraph become Markdown table blocks.
			for table in paragraph.tables where !table.cells.isEmpty {
				if let node = Self.tableMarkup(table) { blocks.append(node) }
			}

			// A maximal run of consecutive list items becomes one (possibly nested) list.
			if paragraph.listLevel != nil {
				var end = index
				while end < paragraphs.count, paragraphs[end].listLevel != nil { end += 1 }
				blocks.append(contentsOf: Self.listMarkup(Array(paragraphs[index..<end])))
				index = end
				continue
			}

			let inlines = Self.inlineMarkup(of: paragraph)
			if !inlines.isEmpty {
				if let level = headingLevel(for: paragraph, text: paragraph.normalizedText(), bodySize: bodySize) {
					blocks.append(Heading(level: level, inlines))
				} else {
					blocks.append(Markdown.Paragraph(inlines))
				}
			}
			index += 1
		}

		// Footnote definitions follow the body (one paragraph each — literal text, since
		// the AST has no footnote node; the formatter emits `[^n]: …` verbatim).
		for footnote in footnotes.sorted(by: { $0.number < $1.number }) {
			blocks.append(Markdown.Paragraph(Text("[^\(footnote.number)]: \(footnote.text)")))
		}
		return Document(blocks)
	}

	// MARK: - Inline

	/// The paragraph's inline content as AST nodes. We render the paragraph's inline
	/// Markdown (text + emphasis/code/link/image/footnote runs) and parse it back, so
	/// the emphasis nesting and link/image shapes are produced by cmark itself.
	static func inlineMarkup(of paragraph: Paragraph) -> [InlineMarkup] {
		inlineChildren(parsing: paragraph.renderedText(inliningImages: true, applyingEmphasis: true))
	}

	/// Parses a fragment of inline Markdown into inline nodes (the children of the first
	/// block). Multiple blocks (shouldn't occur for one paragraph) join with soft breaks.
	static func inlineChildren(parsing markdown: String) -> [InlineMarkup] {
		guard !markdown.isEmpty else { return [] }
		let document = Document(parsing: markdown, options: [])
		var result = [InlineMarkup]()
		for block in document.children {
			let inlines = block.children.compactMap { $0 as? InlineMarkup }
			guard !inlines.isEmpty else { continue }
			if !result.isEmpty { result.append(SoftBreak()) }
			result.append(contentsOf: inlines)
		}
		return result.isEmpty ? [Text(markdown)] : result
	}

	// MARK: - Lists

	/// Builds (possibly nested) list blocks from a run of consecutive list paragraphs.
	/// Items deeper than the run's base level are nested into the preceding item.
	static func listMarkup(_ items: [Paragraph]) -> [BlockMarkup] {
		guard let baseLevel = items.compactMap({ $0.listLevel }).min() else { return [] }
		var blocks = [BlockMarkup]()
		var listItems = [ListItem]()
		var ordered = items.first?.listOrdered ?? false

		func flush() {
			guard !listItems.isEmpty else { return }
			blocks.append(ordered ? OrderedList(listItems) : UnorderedList(listItems))
			listItems = []
		}

		var i = 0
		while i < items.count {
			let level = items[i].listLevel ?? baseLevel
			if level > baseLevel {
				// Gather the deeper sub-run and nest it into the last item at this level.
				var j = i
				while j < items.count, (items[j].listLevel ?? baseLevel) > baseLevel { j += 1 }
				let nested = listMarkup(Array(items[i..<j]))
				if let last = listItems.popLast() {
					listItems.append(ListItem(Array(last.blockChildren) + nested))
				} else {
					blocks.append(contentsOf: nested)
				}
				i = j
				continue
			}
			if items[i].listOrdered != ordered { flush(); ordered = items[i].listOrdered }
			listItems.append(ListItem(Markdown.Paragraph(inlineMarkup(of: items[i]))))
			i += 1
		}
		flush()
		return blocks
	}

	// MARK: - Tables

	/// Builds a GitHub-flavored Markdown table node, parsing each cell's text (which may
	/// carry inline `**`/`*`/`` ` `` markup) so the formatter escapes and re-emits it.
	static func tableMarkup(_ table: Paragraph.Table) -> Markdown.Table? {
		let columns = table.cells.map(\.count).max() ?? 0
		guard columns > 0, !table.cells.isEmpty else { return nil }

		func cell(_ value: String) -> Markdown.Table.Cell {
			Markdown.Table.Cell(inlineChildren(parsing: value.replacingOccurrences(of: "\n", with: " ")))
		}
		func cells(_ row: [String]) -> [Markdown.Table.Cell] {
			(0..<columns).map { $0 < row.count ? cell(row[$0]) : Markdown.Table.Cell() }
		}

		let alignments: [Markdown.Table.ColumnAlignment?] = (0..<columns).map { column in
			switch column < table.columnAlignments.count ? table.columnAlignments[column] : .left {
			case .left: return nil          // a plain `---` separator
			case .center: return .center
			case .right: return .right
			}
		}
		return Markdown.Table(
			columnAlignments: alignments,
			header: Markdown.Table.Head(cells(table.cells[0])),
			body: Markdown.Table.Body(table.cells.dropFirst().map { Markdown.Table.Row(cells($0)) })
		)
	}
}
