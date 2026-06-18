//  Layout.swift
//  SwiftTextRender
//
//  Block and inline layout. A simplified port of WeasyPrint's layout/: block
//  boxes stack vertically honoring the box model; inline content is broken into
//  lines greedily using font metrics. Coordinates are CSS pixels with a
//  y-down, top-left origin; the painter converts to PDF's y-up space.
//
//  Not yet modeled: margin collapsing, floats, absolute positioning, tables,
//  flex/grid. These follow once the vertical slice is proven end to end.

import Foundation
import SwiftTextCSS

public final class LayoutEngine {
	private let fonts: FontBook

	public init(fonts: FontBook) {
		self.fonts = fonts
	}

	/// Lay out a root block in a column of the given content width starting at
	/// `(originX, originY)`. Returns the total margin-box height consumed.
	@discardableResult
	public func layout(root: BlockBox, contentWidth: Double, originX: Double, originY: Double) -> Double {
		let marginTop = root.style.margin.top.resolved(percentageBasis: contentWidth) ?? 0
		let marginBottom = root.style.margin.bottom.resolved(percentageBasis: contentWidth) ?? 0
		let height = layoutBlock(root, containingWidth: contentWidth, marginX: originX, borderBoxTop: originY + marginTop)
		return marginTop + height + marginBottom
	}

	/// Lay out a block whose border box top is at `borderBoxTop`. The caller owns
	/// this box's vertical margins (so adjacent siblings can collapse). Sets the
	/// box's border-box geometry and returns its border-box height.
	private func layoutBlock(_ box: BlockBox, containingWidth: Double, marginX: Double, borderBoxTop: Double) -> Double {
		let style = box.style
		let basis = containingWidth

		let marginLeft = style.margin.left.resolved(percentageBasis: basis) ?? 0

		let border = box.usedBorder
		let paddingLeft = style.padding.left.resolved(percentageBasis: basis) ?? 0
		let paddingRight = style.padding.right.resolved(percentageBasis: basis) ?? 0
		let paddingTop = style.padding.top.resolved(percentageBasis: basis) ?? 0
		let paddingBottom = style.padding.bottom.resolved(percentageBasis: basis) ?? 0

		let marginRight = style.margin.right.resolved(percentageBasis: basis) ?? 0
		let horizontalExtras = marginLeft + marginRight + border.left + border.right + paddingLeft + paddingRight
		let explicitWidth = style.width.resolved(percentageBasis: basis)
		let contentWidth = max(0, explicitWidth ?? (containingWidth - horizontalExtras))
		let borderBoxWidth = contentWidth + paddingLeft + paddingRight + border.left + border.right

		box.x = marginX + marginLeft
		box.y = borderBoxTop
		box.width = borderBoxWidth

		// Replaced image: size from intrinsic dimensions, honoring CSS width/height
		// and preserving aspect ratio when only one is given.
		if let image = box.image {
			let intrinsicWidth = max(1.0, Double(image.width))
			let intrinsicHeight = max(1.0, Double(image.height))
			let cssHeight: Double? = { if case .px(let value) = style.height { return value }; return nil }()
			let usedWidth: Double
			let usedHeight: Double
			switch (explicitWidth, cssHeight) {
			case let (width?, height?): usedWidth = width; usedHeight = height
			case let (width?, nil): usedWidth = width; usedHeight = intrinsicHeight * (width / intrinsicWidth)
			case let (nil, height?): usedHeight = height; usedWidth = intrinsicWidth * (height / intrinsicHeight)
			case (nil, nil): usedWidth = intrinsicWidth; usedHeight = intrinsicHeight
			}
			box.width = usedWidth + paddingLeft + paddingRight + border.left + border.right
			box.height = usedHeight + paddingTop + paddingBottom + border.top + border.bottom
			return box.height
		}

		let contentX = box.x + border.left + paddingLeft
		let contentTop = box.y + border.top + paddingTop

		var contentHeight: Double
		if box.style.display == .table {
			contentHeight = layoutTable(box, contentWidth: contentWidth, contentX: contentX, contentTop: contentTop)
		} else if box.establishesInlineContext {
			contentHeight = layoutInline(box, contentWidth: contentWidth, contentX: contentX, contentTop: contentTop)
		} else {
			// Stack block children, collapsing adjacent sibling vertical margins.
			var cursorY = contentTop
			var previousMarginBottom = 0.0
			var started = false
			for child in box.children {
				guard let childBlock = child as? BlockBox else { continue }
				let childMarginTop = childBlock.style.margin.top.resolved(percentageBasis: contentWidth) ?? 0
				let childMarginBottom = childBlock.style.margin.bottom.resolved(percentageBasis: contentWidth) ?? 0
				cursorY += started ? max(previousMarginBottom, childMarginTop) : childMarginTop
				cursorY += layoutBlock(childBlock, containingWidth: contentWidth, marginX: contentX, borderBoxTop: cursorY)
				previousMarginBottom = childMarginBottom
				started = true
			}
			contentHeight = (cursorY - contentTop) + previousMarginBottom
		}

		// Place a list-item marker just outside the content box, on the side the
		// writing direction starts from: left for LTR, right for RTL.
		if let marker = box.marker, let line = firstLineBox(in: box) {
			let font = fonts.font(for: box.style)
			let markerWidth = font.width(of: marker, size: box.style.fontSize)
			let gap = font.width(of: " ", size: box.style.fontSize)
			let markerX = box.style.direction == .rtl
				? contentX + contentWidth + gap        // right of the content box
				: contentX - markerWidth - gap          // left of the content box
			let fragment = TextFragment(text: marker, style: box.style,
			                            x: markerX, y: line.y,
			                            width: markerWidth, baseline: line.y + line.baseline)
			line.fragments.insert(fragment, at: 0)
		}

		// Only explicit pixel heights are honored; percentages need a resolved
		// containing height and are treated as auto for now.
		if case .px(let fixed) = style.height {
			contentHeight = fixed
		}

		box.height = contentHeight + paddingTop + paddingBottom + border.top + border.bottom
		return box.height
	}

	/// The first line box found in a subtree, if any.
	private func firstLineBox(in box: Box) -> LineBox? {
		guard let block = box as? BlockBox else { return nil }
		if let first = block.lines.first { return first }
		for child in block.children {
			if let line = firstLineBox(in: child) { return line }
		}
		return nil
	}

	// MARK: - Table layout

	private struct CellPlacement {
		let cell: BlockBox
		let row: Int
		let column: Int
		let colspan: Int
		let rowspan: Int
	}

	/// Lay out a `display: table` box as an equal-column grid, honoring colspan
	/// and rowspan. Content-based column sizing is not modeled (columns are
	/// equal width).
	private func layoutTable(_ table: BlockBox, contentWidth: Double, contentX: Double, contentTop: Double) -> Double {
		let rows = collectTableRows(table)
		guard !rows.isEmpty else { return 0 }
		let spacing = 2.0 // border-spacing (UA default)

		// Place cells into a grid, marking spanned slots as occupied.
		var placements: [CellPlacement] = []
		var occupied = Set<Int>()
		func slot(_ row: Int, _ column: Int) -> Int { row * 4096 + column }
		for (rowIndex, row) in rows.enumerated() {
			var column = 0
			for cell in row.cells {
				while occupied.contains(slot(rowIndex, column)) { column += 1 }
				let colspan = spanAttribute(cell, "colspan")
				let rowspan = spanAttribute(cell, "rowspan")
				placements.append(CellPlacement(cell: cell, row: rowIndex, column: column, colspan: colspan, rowspan: rowspan))
				for r in rowIndex ..< rowIndex + rowspan {
					for c in column ..< column + colspan { occupied.insert(slot(r, c)) }
				}
				column += colspan
			}
		}

		let columnCount = placements.map { $0.column + $0.colspan }.max() ?? 0
		guard columnCount > 0 else { return 0 }
		let columnWidth = max(0, (contentWidth - Double(columnCount + 1) * spacing) / Double(columnCount))
		func columnX(_ column: Int) -> Double { contentX + spacing + Double(column) * (columnWidth + spacing) }
		func spanWidth(_ colspan: Int) -> Double { Double(colspan) * columnWidth + Double(colspan - 1) * spacing }

		// Pass 1: measure each cell's height at its column width.
		var measured: [ObjectIdentifier: Double] = [:]
		for placement in placements {
			let height = layoutBlock(placement.cell, containingWidth: spanWidth(placement.colspan),
			                         marginX: columnX(placement.column), borderBoxTop: contentTop)
			measured[ObjectIdentifier(placement.cell)] = height
		}

		// Row heights come from cells confined to a single row.
		var rowHeights = [Double](repeating: 0, count: rows.count)
		for placement in placements where placement.rowspan == 1 {
			rowHeights[placement.row] = max(rowHeights[placement.row], measured[ObjectIdentifier(placement.cell)] ?? 0)
		}
		var rowTops = [Double](repeating: 0, count: rows.count)
		var y = contentTop + spacing
		for index in rows.indices {
			rowTops[index] = y
			y += rowHeights[index] + spacing
		}

		// Pass 2: re-lay out each cell at its final position, stretch to its row(s),
		// and apply vertical-align by shifting the cell's content.
		for placement in placements {
			_ = layoutBlock(placement.cell, containingWidth: spanWidth(placement.colspan),
			                marginX: columnX(placement.column), borderBoxTop: rowTops[placement.row])
			let naturalHeight = placement.cell.height
			let lastRow = min(placement.row + placement.rowspan - 1, rows.count - 1)
			var stretched = 0.0
			for r in placement.row ... lastRow { stretched += rowHeights[r] }
			stretched += Double(lastRow - placement.row) * spacing
			stretched = max(stretched, naturalHeight)
			placement.cell.height = stretched

			let extra = stretched - naturalHeight
			if extra > 0.5 {
				let factor: Double
				switch placement.cell.style.verticalAlign {
				case .middle: factor = 0.5
				case .bottom, .textBottom: factor = 1.0
				default: factor = 0 // top / baseline
				}
				if factor > 0 { shiftBoxContent(placement.cell, by: extra * factor) }
			}
		}

		for (rowIndex, row) in rows.enumerated() {
			row.box.x = contentX
			row.box.y = rowTops[rowIndex]
			row.box.width = contentWidth
			row.box.height = rowHeights[rowIndex]
		}
		return y - contentTop
	}

	/// Shift a box's laid-out content (lines and child boxes) down by `dy`.
	private func shiftBoxContent(_ box: BlockBox, by dy: Double) {
		if box.establishesInlineContext {
			for line in box.lines {
				line.y += dy
				for index in line.fragments.indices {
					line.fragments[index].y += dy
					line.fragments[index].baseline += dy
				}
			}
		} else {
			for child in box.children {
				child.y += dy
				if let childBlock = child as? BlockBox { shiftBoxContent(childBlock, by: dy) }
			}
		}
	}

	private func spanAttribute(_ cell: BlockBox, _ name: String) -> Int {
		guard let value = cell.element?.attributeValue(name),
		      let number = Int(value.trimmingCharacters(in: .whitespaces)) else { return 1 }
		return max(1, number)
	}

	/// Collect table rows (and their cells), descending through row groups.
	private func collectTableRows(_ table: BlockBox) -> [(box: BlockBox, cells: [BlockBox])] {
		var rows: [(box: BlockBox, cells: [BlockBox])] = []
		func walk(_ box: BlockBox) {
			for child in box.children {
				guard let block = child as? BlockBox else { continue }
				switch block.style.display {
				case .tableRow:
					let cells = block.children.compactMap { child -> BlockBox? in
						guard let cell = child as? BlockBox, cell.style.display == .tableCell else { return nil }
						return cell
					}
					rows.append((block, cells))
				case .tableRowGroup, .tableHeaderGroup, .tableFooterGroup:
					walk(block)
				default:
					walk(block)
				}
			}
		}
		walk(table)
		return rows
	}

	// MARK: - Inline layout

	private enum InlineToken {
		case word(String, ComputedStyle, href: String?)
		case space(ComputedStyle)
		case forcedBreak(ComputedStyle)
	}

	/// Lay out the inline content of `box` into lines. Returns the content height.
	private func layoutInline(_ box: BlockBox, contentWidth: Double, contentX: Double, contentTop: Double) -> Double {
		var tokens: [InlineToken] = []
		for child in box.children {
			collectInline(child, into: &tokens, href: nil)
		}

		// Resolve bidi levels over the whole inline content (per paragraph) so each
		// line can be reordered into visual order. Pure-LTR content skips this.
		var bidiScalars: [Unicode.Scalar] = []
		var tokenScalarStart: [Int] = []
		for token in tokens {
			tokenScalarStart.append(bidiScalars.count)
			switch token {
			case .word(let word, _, _): bidiScalars.append(contentsOf: word.unicodeScalars)
			case .space: bidiScalars.append(" ")
			case .forcedBreak: bidiScalars.append("\n")
			}
		}
		let baseDirection: BidiDirection = box.style.direction == .rtl ? .rightToLeft : .leftToRight
		let bidiLevels = Bidi.levels(for: bidiScalars, baseDirection: baseDirection)
		let hasRTL = baseDirection == .rightToLeft || bidiLevels.contains { $0 % 2 == 1 }
		func wordLevel(_ tokenIndex: Int) -> UInt8 {
			guard !bidiLevels.isEmpty else { return baseDirection.baseLevel }
			return bidiLevels[min(tokenScalarStart[tokenIndex], bidiLevels.count - 1)]
		}

		var lines: [LineBox] = []
		var fragments: [TextFragment] = []
		var penX = box.style.textIndent // first line indentation (reset to 0 after)
		var pendingSpace: ComputedStyle?
		var lineTop = contentTop

		func spaceWidth(_ style: ComputedStyle) -> Double {
			fonts.font(for: style).width(of: " ", size: style.fontSize) + style.wordSpacing
		}

		// Place a line's fragments in bidi visual order: reorder by level, reverse
		// RTL runs, and resolve start/end alignment against the base direction.
		func placeBidiLine(_ line: LineBox, _ logical: [TextFragment], baselineFromTop: Double, isFirstLine: Bool) {
			let levels = logical.map { $0.bidiLevel }
			let visual = Bidi.visualOrder(levels: levels)
			var ordered: [TextFragment] = []
			ordered.reserveCapacity(visual.count)
			for index in visual {
				var fragment = logical[index]
				if levels[index] % 2 == 1 {
					fragment.text = String(String.UnicodeScalarView(fragment.text.unicodeScalars.reversed()))
				}
				ordered.append(fragment)
			}

			var total = 0.0
			for (k, fragment) in ordered.enumerated() {
				if k > 0 { total += spaceWidth(ordered[k - 1].style) }
				total += fragment.width
			}
			let extra = max(0, contentWidth - total)
			let rtl = box.style.direction == .rtl
			let indent = isFirstLine ? box.style.textIndent : 0
			var x: Double
			switch box.style.textAlign {
			case .center: x = extra / 2
			case .left: x = indent
			case .right: x = extra - indent
			case .start: x = rtl ? extra - indent : indent
			case .end: x = rtl ? indent : extra - indent
			case .justify: x = rtl ? extra - indent : indent // RTL justify → start for now
			}

			line.width = total
			for (k, fragment) in ordered.enumerated() {
				if k > 0 { x += spaceWidth(ordered[k - 1].style) }
				var positioned = fragment
				positioned.x = contentX + x
				positioned.y = lineTop
				positioned.baseline = lineTop + baselineFromTop
				line.fragments.append(positioned)
				x += fragment.width
			}
		}

		func finishLine(isLast: Bool) {
			guard !fragments.isEmpty else { pendingSpace = nil; return }
			let lineHeight = fragments.map { $0.style.resolvedLineHeight() }.max() ?? 0
			let ascent = fragments.map { fonts.font(for: $0.style).ascent(size: $0.style.fontSize) }.max() ?? 0
			let descent = fragments.map { fonts.font(for: $0.style).descent(size: $0.style.fontSize) }.max() ?? 0
			// Center the text box within the line height (half-leading).
			let baselineFromTop = ascent + (lineHeight - ascent - descent) / 2

			let line = LineBox()
			line.x = contentX
			line.y = lineTop
			line.height = lineHeight
			line.baseline = baselineFromTop

			if hasRTL {
				placeBidiLine(line, fragments, baselineFromTop: baselineFromTop, isFirstLine: lines.isEmpty)
			} else {
				// LTR fast path (unchanged): align and place in logical order.
				let extra = max(0, contentWidth - penX)
				let gaps = fragments.count - 1
				var offset = 0.0
				var perGap = 0.0
				switch box.style.textAlign {
				case .center: offset = extra / 2
				case .right, .end: offset = extra
				case .justify: if !isLast, gaps > 0 { perGap = extra / Double(gaps) }
				default: break // start / left
				}
				line.width = penX + perGap * Double(gaps)
				line.fragments = fragments.enumerated().map { index, fragment in
					var positioned = fragment
					positioned.x += contentX + offset + perGap * Double(index)
					positioned.y = lineTop
					positioned.baseline = lineTop + baselineFromTop
					return positioned
				}
			}
			lines.append(line)

			lineTop += lineHeight
			fragments = []
			penX = 0
			pendingSpace = nil
		}

		for (tokenIndex, token) in tokens.enumerated() {
			switch token {
			case .space(let style):
				if !fragments.isEmpty { pendingSpace = style }
			case .forcedBreak(let style):
				if !fragments.isEmpty {
					finishLine(isLast: false)
				} else {
					// A break with nothing on the line still consumes a line's height.
					let height = style.resolvedLineHeight()
					let blank = LineBox()
					blank.x = contentX
					blank.y = lineTop
					blank.height = height
					blank.baseline = height
					lines.append(blank)
					lineTop += height
				}
				pendingSpace = nil
			case .word(let rawWord, let style, let href):
				// Split the word into runs that share one font (font fallback), then
				// shape each Arabic run into presentation forms. Shaping stays in
				// logical order (one glyph per scalar) so the later bidi pass can
				// reverse the run for visual order; only embedded fonts carry the
				// presentation-form glyphs.
				struct Piece { let text: String; let font: Font; let width: Double }
				var pieces: [Piece] = []
				var wordWidth = 0.0
				for run in fonts.resolveRuns(rawWord, style: style) {
					var text = run.text
					if case .embedded(let embedded) = run.font, ArabicShaper.needsShaping(text) {
						text = ArabicShaper.shape(text, hasForm: { embedded.hasGlyph(for: $0) })
					}
					// letter-spacing adds after every character of the run.
					let width = run.font.width(of: text, size: style.fontSize)
						+ style.letterSpacing * Double(text.unicodeScalars.count)
					pieces.append(Piece(text: text, font: run.font, width: width))
					wordWidth += width
				}
				func gap(_ spaceStyle: ComputedStyle) -> Double {
					// word-spacing adds to each inter-word space.
					fonts.font(for: spaceStyle).width(of: " ", size: spaceStyle.fontSize) + spaceStyle.wordSpacing
				}
				let spaceWidth = pendingSpace.map(gap) ?? 0

				let wraps = style.whiteSpace.wraps
				if wraps && !fragments.isEmpty && penX + spaceWidth + wordWidth > contentWidth {
					finishLine(isLast: false)
				} else if !fragments.isEmpty, let space = pendingSpace {
					penX += gap(space)
					pendingSpace = nil
				}

				// One fragment per font-run; all share the word's bidi level so the
				// reorder treats the word's runs as a unit.
				let level = wordLevel(tokenIndex)
				for piece in pieces {
					let fragment = TextFragment(text: piece.text, style: style, x: penX, y: 0,
					                            width: piece.width, baseline: 0, href: href,
					                            bidiLevel: level, font: piece.font)
					fragments.append(fragment)
					penX += piece.width
				}
			}
		}
		finishLine(isLast: true)

		box.lines = lines
		return lineTop - contentTop
	}

	private func collectInline(_ box: Box, into tokens: inout [InlineToken], href: String?) {
		if let text = box as? TextBox {
			let style = text.style
			if style.whiteSpace == .pre {
				// Preserve spaces verbatim; only newlines break the line. (pre does
				// not wrap, so each segment between newlines is one fragment.)
				var segment = ""
				for character in text.text {
					if character == "\n" {
						if !segment.isEmpty { tokens.append(.word(segment, style, href: href)); segment = "" }
						tokens.append(.forcedBreak(style))
					} else if character != "\r" {
						segment.append(character)
					}
				}
				if !segment.isEmpty { tokens.append(.word(segment, style, href: href)) }
				return
			}
			let content = style.whiteSpace.collapsesWhitespace ? collapseWhitespace(text.text) : text.text
			var word = ""
			func flushWord() {
				if !word.isEmpty { tokens.append(.word(word, style, href: href)); word = "" }
			}
			for character in content {
				if character == "\n" && !style.whiteSpace.collapsesWhitespace {
					// Preserved newline (white-space: pre/pre-wrap/pre-line).
					flushWord()
					tokens.append(.forcedBreak(style))
				} else if character == " " || character == "\t" || character == "\n" {
					flushWord()
					tokens.append(.space(style))
				} else {
					word.append(character)
				}
			}
			flushWord()
		} else if let inline = box as? InlineBox {
			// A <br> forces a line break.
			if inline.element?.localName == "br" {
				tokens.append(.forcedBreak(inline.style))
				return
			}
			// An <a href> establishes a link for its descendant text.
			let childHref: String?
			if inline.element?.localName == "a", let linkURL = inline.element?.attributeValue("href") {
				childHref = linkURL
			} else {
				childHref = href
			}
			for child in inline.children { collectInline(child, into: &tokens, href: childHref) }
		}
	}

	private func collapseWhitespace(_ text: String) -> String {
		var result = ""
		var previousWasSpace = false
		for character in text {
			let isSpace = character == " " || character == "\t" || character == "\n" || character == "\r"
			if isSpace {
				if !previousWasSpace { result.append(" ") }
				previousWasSpace = true
			} else {
				result.append(character)
				previousWasSpace = false
			}
		}
		return result
	}
}
