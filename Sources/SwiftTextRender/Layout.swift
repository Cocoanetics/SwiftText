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
#if canImport(Darwin)
import CoreFoundation
#endif

public final class LayoutEngine {
	private let fonts: FontBook

	private func preferredLineBreakOffsets(in word: String) -> Set<Int> {
		#if canImport(Darwin)
		let string = word as CFString
		let length = CFStringGetLength(string)
		let tokenizer = CFStringTokenizerCreate(nil, string, CFRange(location: 0, length: length),
		                                        kCFStringTokenizerUnitLineBreak, nil)
		var offsets = Set<Int>()
		while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
			let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
			let offset = range.location + range.length
			if offset < length { offsets.insert(offset) }
		}
		return offsets
		#else
		// Core Foundation's line-break tokenizer is Darwin-only. Keep the
		// portable engines consistent for the common UAX #14 HY/SY cases.
		let breakAfter: Set<UInt32> = [
			0x002D, // HYPHEN-MINUS (HY)
			0x002F, // SOLIDUS (SY)
			0x058A, 0x05BE, 0x1400, 0x2010, 0x2012, 0x2013, 0x2014, 0x2E17, 0x2E40
		]
		let length = word.utf16.count
		var utf16Offset = 0
		var offsets = Set<Int>()
		for character in word {
			utf16Offset += character.utf16.count
			if utf16Offset < length,
			   character.unicodeScalars.count == 1,
			   let scalar = character.unicodeScalars.first,
			   breakAfter.contains(scalar.value) {
				offsets.insert(utf16Offset)
			}
		}
		return offsets
		#endif
	}

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
		if style.display == .table {
			resolveCollapsedBorders(in: box)
		}

		let marginLeft = style.margin.left.resolved(percentageBasis: basis) ?? 0

		let border = box.usedBorder
		let paddingLeft = style.padding.left.resolved(percentageBasis: basis) ?? 0
		let paddingRight = style.padding.right.resolved(percentageBasis: basis) ?? 0
		let paddingTop = style.padding.top.resolved(percentageBasis: basis) ?? 0
		let paddingBottom = style.padding.bottom.resolved(percentageBasis: basis) ?? 0

		let marginRight = style.margin.right.resolved(percentageBasis: basis) ?? 0
		let horizontalExtras = marginLeft + marginRight + border.left + border.right + paddingLeft + paddingRight
		let explicitWidth = style.width.resolved(percentageBasis: basis)
		let availableWidth = containingWidth - horizontalExtras
		let unclampedWidth = explicitWidth ?? availableWidth
		let maximumWidth = style.maxWidth?.resolved(percentageBasis: basis)
		let contentWidth = max(0, min(unclampedWidth, maximumWidth ?? unclampedWidth))
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

	private struct TableRow {
		let box: BlockBox
		let cells: [BlockBox]
		let groups: [BlockBox]
	}

	private enum BorderSide {
		case top, right, bottom, left
	}

	private enum BorderSource: Int {
		case table
		case rowGroup
		case row
		case cell
	}

	private struct BorderCandidate {
		let border: CollapsedBorder
		let source: BorderSource
		let box: BlockBox
		let side: BorderSide
	}

	private struct TableGrid {
		let rows: [TableRow]
		let placements: [CellPlacement]
		let slots: [Int: CellPlacement]
		let columnCount: Int
	}

	private func borderCandidate(_ box: BlockBox, side: BorderSide, source: BorderSource) -> BorderCandidate {
		let width: Double
		let style: BorderStyle
		let color: RGBA
		switch side {
		case .top:
			width = box.style.borderWidth.top
			style = box.style.borderStyle.top
			color = box.style.borderColor.top
		case .right:
			width = box.style.borderWidth.right
			style = box.style.borderStyle.right
			color = box.style.borderColor.right
		case .bottom:
			width = box.style.borderWidth.bottom
			style = box.style.borderStyle.bottom
			color = box.style.borderColor.bottom
		case .left:
			width = box.style.borderWidth.left
			style = box.style.borderStyle.left
			color = box.style.borderColor.left
		}
		return BorderCandidate(border: CollapsedBorder(width: width, style: style, color: color),
		                       source: source, box: box, side: side)
	}

	private func winningBorder(_ candidates: [BorderCandidate]) -> BorderCandidate? {
		func styleRank(_ style: BorderStyle) -> Int {
			switch style {
			case .none: return 0
			case .inset: return 1
			case .groove: return 2
			case .outset: return 3
			case .ridge: return 4
			case .dotted: return 5
			case .dashed: return 6
			case .solid: return 7
			case .double: return 8
			case .hidden: return 9
			}
		}

		func outranks(_ candidate: BorderCandidate, _ winner: BorderCandidate) -> Bool {
			let candidateHidden = candidate.border.style == .hidden
			let winnerHidden = winner.border.style == .hidden
			if candidateHidden != winnerHidden { return candidateHidden }
			let candidateVisible = candidate.border.style != .none && candidate.border.width > 0
			let winnerVisible = winner.border.style != .none && winner.border.width > 0
			if candidateVisible != winnerVisible { return candidateVisible }
			if candidate.border.width != winner.border.width {
				return candidate.border.width > winner.border.width
			}
			let candidateStyle = styleRank(candidate.border.style)
			let winnerStyle = styleRank(winner.border.style)
			if candidateStyle != winnerStyle { return candidateStyle > winnerStyle }
			return candidate.source.rawValue > winner.source.rawValue
		}

		guard var winner = candidates.first else { return nil }
		for candidate in candidates.dropFirst() where outranks(candidate, winner) {
			winner = candidate
		}
		return winner
	}

	private func setResolvedBorder(_ border: CollapsedBorder, on box: BlockBox, side: BorderSide) {
		guard border.style != .hidden, border.style != .none, border.width > 0 else { return }
		guard var resolved = box.resolvedCollapsedBorders else { return }
		func stronger(_ existing: CollapsedBorder?) -> CollapsedBorder {
			guard let existing else { return border }
			let old = BorderCandidate(border: existing, source: .cell, box: box, side: side)
			let new = BorderCandidate(border: border, source: .cell, box: box, side: side)
			return winningBorder([old, new])?.border ?? existing
		}
		switch side {
		case .top: resolved.top = stronger(resolved.top)
		case .right: resolved.right = stronger(resolved.right)
		case .bottom: resolved.bottom = stronger(resolved.bottom)
		case .left: resolved.left = stronger(resolved.left)
		}
		box.resolvedCollapsedBorders = resolved
	}

	private func resolveCollapsedBorders(in table: BlockBox) {
		guard table.style.borderCollapse == .collapse else { return }
		let grid = tableGrid(for: table)
		guard !grid.rows.isEmpty, grid.columnCount > 0 else { return }

		var boxes: [BlockBox] = [table]
		for row in grid.rows {
			boxes.append(row.box)
			boxes.append(contentsOf: row.groups)
			boxes.append(contentsOf: row.cells)
		}
		var seen = Set<ObjectIdentifier>()
		for box in boxes where seen.insert(ObjectIdentifier(box)).inserted {
			box.resolvedCollapsedBorders = Edges(nil)
		}

		func slot(_ row: Int, _ column: Int) -> CellPlacement? {
			grid.slots[row * 4096 + column]
		}
		func sameCell(_ lhs: CellPlacement?, _ rhs: CellPlacement?) -> Bool {
			guard let lhs, let rhs else { return false }
			return lhs.cell === rhs.cell
		}
		func contains(_ groups: [BlockBox], _ group: BlockBox) -> Bool {
			groups.contains { $0 === group }
		}

		// Resolve one vertical segment per row and column boundary. Cell borders
		// compete on interior edges; row, row-group, and table sides join the
		// candidates at the outside of the grid.
		for rowIndex in grid.rows.indices {
			let row = grid.rows[rowIndex]
			for column in 0 ... grid.columnCount {
				let left = column > 0 ? slot(rowIndex, column - 1) : nil
				let right = column < grid.columnCount ? slot(rowIndex, column) : nil
				if sameCell(left, right) { continue }
				var candidates: [BorderCandidate] = []
				if let left { candidates.append(borderCandidate(left.cell, side: .right, source: .cell)) }
				if let right { candidates.append(borderCandidate(right.cell, side: .left, source: .cell)) }
				if column == 0 {
					candidates.append(borderCandidate(row.box, side: .left, source: .row))
					candidates.append(contentsOf: row.groups.map { borderCandidate($0, side: .left, source: .rowGroup) })
					candidates.append(borderCandidate(table, side: .left, source: .table))
				} else if column == grid.columnCount {
					candidates.append(borderCandidate(row.box, side: .right, source: .row))
					candidates.append(contentsOf: row.groups.map { borderCandidate($0, side: .right, source: .rowGroup) })
					candidates.append(borderCandidate(table, side: .right, source: .table))
				}
				guard let winner = winningBorder(candidates) else { continue }
				let owner = winner.source == .cell ? winner
					: left.map { borderCandidate($0.cell, side: .right, source: .cell) }
						?? right.map { borderCandidate($0.cell, side: .left, source: .cell) }
				if let owner { setResolvedBorder(winner.border, on: owner.box, side: owner.side) }
			}
		}

		// Resolve horizontal segments between rows. A row-group side participates
		// only where the adjoining row falls outside that group.
		for rowBoundary in 0 ... grid.rows.count {
			let upperRow = rowBoundary > 0 ? grid.rows[rowBoundary - 1] : nil
			let lowerRow = rowBoundary < grid.rows.count ? grid.rows[rowBoundary] : nil
			for column in 0 ..< grid.columnCount {
				let upper = rowBoundary > 0 ? slot(rowBoundary - 1, column) : nil
				let lower = rowBoundary < grid.rows.count ? slot(rowBoundary, column) : nil
				if sameCell(upper, lower) { continue }
				var candidates: [BorderCandidate] = []
				if let upper { candidates.append(borderCandidate(upper.cell, side: .bottom, source: .cell)) }
				if let lower { candidates.append(borderCandidate(lower.cell, side: .top, source: .cell)) }
				if let upperRow { candidates.append(borderCandidate(upperRow.box, side: .bottom, source: .row)) }
				if let lowerRow { candidates.append(borderCandidate(lowerRow.box, side: .top, source: .row)) }
				if let upperRow {
					for group in upperRow.groups where lowerRow.map({ !contains($0.groups, group) }) ?? true {
						candidates.append(borderCandidate(group, side: .bottom, source: .rowGroup))
					}
				}
				if let lowerRow {
					for group in lowerRow.groups where upperRow.map({ !contains($0.groups, group) }) ?? true {
						candidates.append(borderCandidate(group, side: .top, source: .rowGroup))
					}
				}
				if rowBoundary == 0 {
					candidates.append(borderCandidate(table, side: .top, source: .table))
				} else if rowBoundary == grid.rows.count {
					candidates.append(borderCandidate(table, side: .bottom, source: .table))
				}
				guard let winner = winningBorder(candidates) else { continue }
				let owner = winner.source == .cell ? winner
					: upper.map { borderCandidate($0.cell, side: .bottom, source: .cell) }
						?? lower.map { borderCandidate($0.cell, side: .top, source: .cell) }
				if let owner { setResolvedBorder(winner.border, on: owner.box, side: owner.side) }
			}
		}
	}

	private func tableGrid(for table: BlockBox) -> TableGrid {
		let rows = collectTableRows(table)
		var placements: [CellPlacement] = []
		var slots: [Int: CellPlacement] = [:]
		func slot(_ row: Int, _ column: Int) -> Int { row * 4096 + column }
		for (rowIndex, row) in rows.enumerated() {
			var column = 0
			for cell in row.cells {
				while slots[slot(rowIndex, column)] != nil { column += 1 }
				let colspan = spanAttribute(cell, "colspan")
				let rowspan = spanAttribute(cell, "rowspan")
				let placement = CellPlacement(cell: cell, row: rowIndex, column: column,
				                              colspan: colspan, rowspan: rowspan)
				placements.append(placement)
				for r in rowIndex ..< rowIndex + rowspan {
					for c in column ..< column + colspan { slots[slot(r, c)] = placement }
				}
				column += colspan
			}
		}
		return TableGrid(rows: rows, placements: placements, slots: slots,
		                 columnCount: placements.map { $0.column + $0.colspan }.max() ?? 0)
	}

	/// Lay out a `display: table` box as a content-sized column grid, honoring
	/// colspan and rowspan.
	private func layoutTable(_ table: BlockBox, contentWidth: Double, contentX: Double, contentTop: Double) -> Double {
		let grid = tableGrid(for: table)
		let rows = grid.rows
		guard !rows.isEmpty else { return 0 }
		let collapsed = table.style.borderCollapse == .collapse
		let horizontalSpacing = collapsed ? 0 : table.style.borderSpacing.horizontal
		let verticalSpacing = collapsed ? 0 : table.style.borderSpacing.vertical

		let placements = grid.placements
		let columnCount = grid.columnCount
		guard columnCount > 0 else { return 0 }
		let columnWidths = tableColumnWidths(placements, columnCount: columnCount,
		                                    availableWidth: max(0, contentWidth - Double(columnCount + 1) * horizontalSpacing),
		                                    spacing: horizontalSpacing)
		func columnX(_ column: Int) -> Double {
			contentX + horizontalSpacing + columnWidths[..<column].reduce(0, +) + Double(column) * horizontalSpacing
		}
		func spanWidth(_ column: Int, _ colspan: Int) -> Double {
			columnWidths[column ..< min(column + colspan, columnCount)].reduce(0, +)
				+ Double(colspan - 1) * horizontalSpacing
		}

		// Pass 1: measure each cell's height at its column width.
		var measured: [ObjectIdentifier: Double] = [:]
		for placement in placements {
			let height = layoutBlock(placement.cell, containingWidth: spanWidth(placement.column, placement.colspan),
			                         marginX: columnX(placement.column), borderBoxTop: contentTop)
			measured[ObjectIdentifier(placement.cell)] = height
		}

		// Row heights come from cells confined to a single row.
		var rowHeights = [Double](repeating: 0, count: rows.count)
		for placement in placements where placement.rowspan == 1 {
			rowHeights[placement.row] = max(rowHeights[placement.row], measured[ObjectIdentifier(placement.cell)] ?? 0)
		}
		// A spanning cell can require more height than the rows it covers get from
		// their single-row cells. Share that deficit across the span so the table's
		// flow height contains the cell instead of letting it overlap later content.
		for placement in placements where placement.rowspan > 1 {
			let lastRow = min(placement.row + placement.rowspan - 1, rows.count - 1)
			let spannedRows = placement.row ... lastRow
			let currentHeight = spannedRows.reduce(0.0) { $0 + rowHeights[$1] }
				+ Double(lastRow - placement.row) * verticalSpacing
			let deficit = (measured[ObjectIdentifier(placement.cell)] ?? 0) - currentHeight
			if deficit > 0 {
				let share = deficit / Double(spannedRows.count)
				for row in spannedRows { rowHeights[row] += share }
			}
		}
		var rowTops = [Double](repeating: 0, count: rows.count)
		var y = contentTop + verticalSpacing
		for index in rows.indices {
			rowTops[index] = y
			y += rowHeights[index] + verticalSpacing
		}

		// Pass 2: re-lay out each cell at its final position, stretch to its row(s),
		// and apply vertical-align by shifting the cell's content.
		for placement in placements {
			_ = layoutBlock(placement.cell, containingWidth: spanWidth(placement.column, placement.colspan),
			                marginX: columnX(placement.column), borderBoxTop: rowTops[placement.row])
			let naturalHeight = placement.cell.height
			let lastRow = min(placement.row + placement.rowspan - 1, rows.count - 1)
			var stretched = 0.0
			for r in placement.row ... lastRow { stretched += rowHeights[r] }
			stretched += Double(lastRow - placement.row) * verticalSpacing
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
		// Row groups are transparent to grid layout, but they still need geometry:
		// the painter uses every block's bounds to prune off-page subtrees. Leaving
		// a <thead>/<tbody>/<tfoot> at its zero-sized default makes it intersect only
		// the first page and silently drops all of its later rows.
		let bounds = sizeTableRowGroups(in: table, contentX: contentX, contentWidth: contentWidth)
		return max(y, (bounds?.bottom ?? contentTop) + verticalSpacing) - contentTop
	}

	/// Approximate CSS automatic table layout with each cell's max-content width.
	/// If the preferred widths do not fit, reduce every column proportionally so
	/// the grid remains inside the table's available width.
	private func tableColumnWidths(_ placements: [CellPlacement], columnCount: Int,
	                               availableWidth: Double, spacing: Double) -> [Double] {
		var widths = [Double](repeating: 0, count: columnCount)

		// Establish ordinary columns first. Colspan requirements are applied after
		// that so they only add the width not already supplied by their columns.
		for placement in placements where placement.colspan == 1 {
			widths[placement.column] = max(widths[placement.column], maxContentWidth(of: placement.cell))
		}
		for placement in placements.filter({ $0.colspan > 1 }).sorted(by: { $0.colspan < $1.colspan }) {
			let end = min(placement.column + placement.colspan, columnCount)
			let columns = placement.column ..< end
			let current = widths[columns].reduce(0, +) + Double(columns.count - 1) * spacing
			let deficit = maxContentWidth(of: placement.cell) - current
			if deficit > 0 {
				let share = deficit / Double(columns.count)
				for column in columns { widths[column] += share }
			}
		}

		let preferredWidth = widths.reduce(0, +)
		guard preferredWidth > 0 else {
			return [Double](repeating: availableWidth / Double(columnCount), count: columnCount)
		}
		guard preferredWidth > availableWidth else { return widths }
		let scale = availableWidth / preferredWidth
		return widths.map { $0 * scale }
	}

	/// The border-box width a block needs when none of its inline content wraps.
	private func maxContentWidth(of box: BlockBox) -> Double {
		let border = box.usedBorder
		let padding = (box.style.padding.left.resolved(percentageBasis: 0) ?? 0)
			+ (box.style.padding.right.resolved(percentageBasis: 0) ?? 0)
		let margins = (box.style.margin.left.resolved(percentageBasis: 0) ?? 0)
			+ (box.style.margin.right.resolved(percentageBasis: 0) ?? 0)
		let extras = border.left + border.right + padding + margins

		let contentWidth: Double
		if let image = box.image {
			contentWidth = box.style.width.resolved(percentageBasis: 0) ?? Double(image.width)
		} else if box.establishesInlineContext {
			var tokens: [InlineToken] = []
			for child in box.children { collectInline(child, into: &tokens, href: nil) }
			contentWidth = maxContentWidth(of: tokens, textIndent: box.style.textIndent)
		} else {
			contentWidth = box.children.compactMap { $0 as? BlockBox }.map(maxContentWidth(of:)).max() ?? 0
		}
		let specifiedWidth = box.style.width.resolved(percentageBasis: 0) ?? 0
		return max(contentWidth, specifiedWidth) + extras
	}

	private func maxContentWidth(of tokens: [InlineToken], textIndent: Double) -> Double {
		var maximum = 0.0
		var lineWidth = textIndent
		var hasContent = false
		var pendingSpace: ComputedStyle?
		for token in tokens {
			switch token {
			case .space(let style):
				if hasContent { pendingSpace = style }
			case .forcedBreak:
				maximum = max(maximum, lineWidth)
				lineWidth = 0
				hasContent = false
				pendingSpace = nil
			case .checkbox(_, let style):
				if hasContent, let space = pendingSpace {
					lineWidth += fonts.font(for: space).width(of: " ", size: space.fontSize) + space.wordSpacing
				}
				lineWidth += (style.margin.left.resolved(percentageBasis: 0) ?? 0)
					+ style.fontSize
					+ (style.margin.right.resolved(percentageBasis: 0) ?? 0)
				hasContent = true
				pendingSpace = nil
			case .word(let word, let style, _):
				if hasContent, let space = pendingSpace {
					lineWidth += fonts.font(for: space).width(of: " ", size: space.fontSize) + space.wordSpacing
				}
				for run in fonts.resolveRuns(word, style: style) {
					lineWidth += run.font.width(of: run.text, size: style.fontSize)
						+ style.letterSpacing * Double(run.text.unicodeScalars.count)
				}
				hasContent = true
				pendingSpace = nil
			}
		}
		return max(maximum, lineWidth)
	}

	/// Give table rows and row-group boxes bounds that contain their laid-out
	/// descendants. The groups do not affect grid sizing, but every ancestor must
	/// contain its descendants for pagination-time subtree culling.
	private func sizeTableRowGroups(in box: BlockBox, contentX: Double, contentWidth: Double) -> (top: Double, bottom: Double)? {
		var top = Double.infinity
		var bottom = -Double.infinity
		for child in box.children {
			guard let block = child as? BlockBox else { continue }
			let bounds: (top: Double, bottom: Double)?
			switch block.style.display {
			case .tableRow:
				// Rowspan cells remain children of their starting row. Enlarge that
				// row's paint bounds to contain them so page-slice pruning can still
				// reach the cell on every page it intersects.
				let childBottom = block.children.reduce(block.y + block.height) {
					max($0, $1.y + $1.height)
				}
				block.height = childBottom - block.y
				bounds = (block.y, childBottom)
			case .tableRowGroup, .tableHeaderGroup, .tableFooterGroup:
				bounds = sizeTableRowGroups(in: block, contentX: contentX, contentWidth: contentWidth)
				if let bounds {
					block.x = contentX
					block.y = bounds.top
					block.width = contentWidth
					block.height = bounds.bottom - bounds.top
				}
			default:
				bounds = sizeTableRowGroups(in: block, contentX: contentX, contentWidth: contentWidth)
			}
			if let bounds {
				top = min(top, bounds.top)
				bottom = max(bottom, bounds.bottom)
			}
		}
		return top.isFinite && bottom.isFinite ? (top, bottom) : nil
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
	private func collectTableRows(_ table: BlockBox) -> [TableRow] {
		var rows: [TableRow] = []
		func walk(_ box: BlockBox, groups: [BlockBox]) {
			for child in box.children {
				guard let block = child as? BlockBox else { continue }
				switch block.style.display {
				case .tableRow:
					let cells = block.children.compactMap { child -> BlockBox? in
						guard let cell = child as? BlockBox, cell.style.display == .tableCell else { return nil }
						return cell
					}
					rows.append(TableRow(box: block, cells: cells, groups: groups))
				case .tableRowGroup, .tableHeaderGroup, .tableFooterGroup:
					walk(block, groups: groups + [block])
				case .table:
					continue
				default:
					walk(block, groups: groups)
				}
			}
		}
		walk(table, groups: [])
		return rows
	}
}

// MARK: - Inline layout

private extension LayoutEngine {

	private enum InlineToken {
		case word(String, ComputedStyle, href: String?)
		case checkbox(isChecked: Bool, style: ComputedStyle)
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
			case .checkbox: bidiScalars.append("\u{FFFC}")
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
			case .checkbox(let isChecked, let style):
				let leadingMargin = style.margin.left.resolved(percentageBasis: contentWidth) ?? 0
				let trailingMargin = style.margin.right.resolved(percentageBasis: contentWidth) ?? 0
				let size = style.fontSize
				let width = leadingMargin + size + trailingMargin
				let precedingSpaceWidth = pendingSpace.map(spaceWidth) ?? 0
				if style.whiteSpace.wraps, penX + precedingSpaceWidth + width > contentWidth, !fragments.isEmpty {
					finishLine(isLast: false)
				} else {
					penX += precedingSpaceWidth
					pendingSpace = nil
				}

				var fragment = TextFragment(
					text: "", style: style, x: penX, y: 0, width: width, baseline: 0,
					bidiLevel: wordLevel(tokenIndex), font: fonts.font(for: style))
				fragment.inlineControl = .checkbox(
					isChecked: isChecked, size: size, leadingMargin: leadingMargin)
				fragments.append(fragment)
				penX += width
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
				let level = wordLevel(tokenIndex)
				func append(_ pieces: [Piece]) {
					for piece in pieces {
						if let last = fragments.indices.last,
						   fragments[last].font?.key == piece.font.key,
						   fragments[last].style == style,
						   fragments[last].href == href,
						   fragments[last].bidiLevel == level,
						   abs(fragments[last].x + fragments[last].width - penX) < 0.001 {
							fragments[last].text += piece.text
							fragments[last].width += piece.width
							penX += piece.width
							continue
						}
						let fragment = TextFragment(text: piece.text, style: style, x: penX, y: 0,
						                            width: piece.width, baseline: 0, href: href,
						                            bidiLevel: level, font: piece.font)
						fragments.append(fragment)
						penX += piece.width
					}
				}
				func gap(_ spaceStyle: ComputedStyle) -> Double {
					// word-spacing adds to each inter-word space.
					fonts.font(for: spaceStyle).width(of: " ", size: spaceStyle.fontSize) + spaceStyle.wordSpacing
				}
				func appendWithBreaks(_ pieces: [Piece], preferringSoftBreaks: Bool, breakingAnywhere: Bool) {
					let units = pieces.flatMap { piece in
						piece.text.map { character in
							let text = String(character)
							let width = piece.font.width(of: text, size: style.fontSize)
								+ style.letterSpacing * Double(text.unicodeScalars.count)
							return Piece(text: text, font: piece.font, width: width)
						}
					}
					var preferredBreaks = Set<Int>()
					if preferringSoftBreaks {
						let word = pieces.map(\.text).joined()
						let utf16BreakOffsets = preferredLineBreakOffsets(in: word)
						var utf16Offset = 0
						for (offset, unit) in units.enumerated() {
							utf16Offset += unit.text.utf16.count
							if utf16BreakOffsets.contains(utf16Offset) {
								preferredBreaks.insert(offset + 1)
							}
						}
					}
					var chunkText = ""
					var chunkWidth = 0.0
					var chunkFont: Font?
					func flushChunk() {
						guard let font = chunkFont else { return }
						append([Piece(text: chunkText, font: font, width: chunkWidth)])
						chunkText = ""
						chunkWidth = 0
						chunkFont = nil
					}
					func appendUnits(_ units: ArraySlice<Piece>, breakingAnywhere: Bool) {
						for unit in units {
							if breakingAnywhere,
							   penX + chunkWidth + unit.width > contentWidth,
							   !chunkText.isEmpty || !fragments.isEmpty {
								flushChunk()
								finishLine(isLast: false)
							}
							if let font = chunkFont, font.key != unit.font.key {
								flushChunk()
							}
							chunkFont = unit.font
							chunkText += unit.text
							chunkWidth += unit.width
						}
						flushChunk()
					}
					var segmentStart = 0
					for segmentEnd in preferredBreaks.sorted() + [units.count] {
						let segment = units[segmentStart ..< segmentEnd]
						let segmentWidth = segment.reduce(0) { $0 + $1.width }
						if segmentStart == 0, !fragments.isEmpty, let space = pendingSpace {
							let width = gap(space)
							if penX + width + segmentWidth > contentWidth {
								finishLine(isLast: false)
							} else {
								penX += width
								pendingSpace = nil
							}
						}
						if penX + segmentWidth > contentWidth, !fragments.isEmpty {
							finishLine(isLast: false)
						}
						appendUnits(segment, breakingAnywhere: breakingAnywhere)
						segmentStart = segmentEnd
					}
				}
				let spaceWidth = pendingSpace.map(gap) ?? 0

				let wraps = style.whiteSpace.wraps
				let breaksAnywhere = style.overflowWrap != .normal || style.wordBreak == .breakWord
				if wraps && style.wordBreak == .breakAll {
					if !fragments.isEmpty, let space = pendingSpace {
						let width = gap(space)
						if penX + width > contentWidth {
							finishLine(isLast: false)
						} else {
							penX += width
							pendingSpace = nil
						}
					}
					if penX + wordWidth > contentWidth {
						appendWithBreaks(pieces, preferringSoftBreaks: false, breakingAnywhere: true)
					} else {
						append(pieces)
					}
				} else {
					if !wraps || penX + spaceWidth + wordWidth <= contentWidth {
						if !fragments.isEmpty, let space = pendingSpace {
							penX += gap(space)
							pendingSpace = nil
						}
						append(pieces)
					} else {
						appendWithBreaks(pieces, preferringSoftBreaks: true, breakingAnywhere: breaksAnywhere)
					}
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
			// Checkboxes are replaced inline content: reserve a one-em square and
			// paint it directly rather than relying on a font's symbol coverage.
			if inline.element?.localName == "input",
			   inline.element?.attributeValue("type")?.lowercased() == "checkbox" {
				tokens.append(.checkbox(
					isChecked: inline.element?.attributeValue("checked") != nil,
					style: inline.style))
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
