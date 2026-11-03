//  Layout.swift
//  SwiftTextRender
//
//  Block and inline layout. A simplified port of WeasyPrint's layout/: block
//  boxes stack vertically honoring the box model; inline content is broken into
//  lines greedily using font metrics. Coordinates are CSS pixels with a
//  y-down, top-left origin; the painter converts to PDF's y-up space.
//
//  Not yet modeled: floats, absolute positioning, flex/grid, and margin
//  collapsing beyond adjacent siblings.

import Foundation
import SwiftTextCSS

public final class LayoutEngine {
	let fonts: FontBook

	/// Intrinsic widths measured during the current layout. Every enclosing
	/// table measures a nested table's cells again, so without them the work
	/// doubles with each level of nesting — and email nests tables deeply.
	private var intrinsicWidths: [IntrinsicWidthKey: Double] = [:]

	private struct IntrinsicWidthKey: Hashable {
		let box: ObjectIdentifier
		let size: IntrinsicSize
	}

	public init(fonts: FontBook) {
		self.fonts = fonts
	}

	/// Lay out a root block in a column of the given content width starting at
	/// `(originX, originY)`. Returns the total margin-box height consumed.
	@discardableResult
	public func layout(root: BlockBox, contentWidth: Double, originX: Double, originY: Double) -> Double {
		intrinsicWidths = [:]
		defer { intrinsicWidths = [:] }
		let marginTop = root.style.margin.top.resolved(percentageBasis: contentWidth) ?? 0
		let marginBottom = root.style.margin.bottom.resolved(percentageBasis: contentWidth) ?? 0
		let height = layoutBlock(root, containingWidth: contentWidth, marginX: originX, borderBoxTop: originY + marginTop)
		return marginTop + height + marginBottom
	}

	/// Lay out a block whose border box top is at `borderBoxTop`. The caller owns
	/// this box's vertical margins (so adjacent siblings can collapse). Sets the
	/// box's border-box geometry and returns its border-box height.
	///
	/// - Parameter containerAlign: The containing block's `text-align`, whose
	///   legacy `-webkit-*` values also align a narrower block.
	private func layoutBlock(_ box: BlockBox, containingWidth: Double, marginX: Double, borderBoxTop: Double,
	                         containerAlign: TextAlign = .start) -> Double {
		let style = box.style
		let basis = containingWidth
		let isTable = style.display == .table
		// A cell is exactly as wide as its column(s): the width, min-width and
		// max-width it asked for were already spent sizing them.
		let isCell = style.display == .tableCell
		if isTable {
			resolveCollapsedBorders(in: box)
		}

		let marginLeft = style.margin.left.resolved(percentageBasis: basis) ?? 0

		let border = box.usedBorder
		let paddingLeft = style.padding.left.resolved(percentageBasis: basis) ?? 0
		let paddingRight = style.padding.right.resolved(percentageBasis: basis) ?? 0
		let paddingTop = style.padding.top.resolved(percentageBasis: basis) ?? 0
		let paddingBottom = style.padding.bottom.resolved(percentageBasis: basis) ?? 0

		let marginRight = style.margin.right.resolved(percentageBasis: basis) ?? 0
		let paddingAndBorder = border.left + border.right + paddingLeft + paddingRight
		let explicitWidth = isCell ? nil : style.width.resolved(percentageBasis: basis)
		let availableWidth = containingWidth - marginLeft - marginRight - paddingAndBorder
		let maximumWidth = isCell ? nil : style.maxWidth?.resolved(percentageBasis: basis)
		let minimumWidth = isCell ? 0 : style.minWidth.resolved(percentageBasis: basis) ?? 0
		var imageHeight = 0.0
		let contentWidth: Double
		if let image = box.image {
			// Replaced image: size from intrinsic dimensions, honoring CSS
			// width/height and preserving aspect ratio when only one is given.
			let size = replacedSize(of: image, style: style, containingWidth: basis)
			contentWidth = size.width
			imageHeight = size.height
		} else if isTable {
			// A table's widths cover its border box, as browsers size tables.
			contentWidth = tableContentWidth(box, specifiedWidth: explicitWidth.map { $0 - paddingAndBorder },
			                                 availableWidth: availableWidth, minimumWidth: minimumWidth - paddingAndBorder,
			                                 maximumWidth: maximumWidth.map { $0 - paddingAndBorder })
		} else {
			let unclampedWidth = explicitWidth ?? availableWidth
			// `min-width` wins over `max-width` when the two conflict (CSS 2.1 §10.4).
			let cappedWidth = min(unclampedWidth, maximumWidth ?? unclampedWidth)
			contentWidth = max(0, max(cappedWidth, minimumWidth))
		}
		let borderBoxWidth = contentWidth + paddingAndBorder

		let freeWidth = containingWidth - marginLeft - borderBoxWidth - marginRight
		box.x = marginX + marginLeft + horizontalOffset(freeWidth: freeWidth, margin: style.margin, containerAlign: containerAlign)
		box.y = borderBoxTop
		box.width = borderBoxWidth

		if box.image != nil {
			box.height = imageHeight + paddingTop + paddingBottom + border.top + border.bottom
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
				cursorY += layoutBlock(childBlock, containingWidth: contentWidth, marginX: contentX, borderBoxTop: cursorY,
				                       containerAlign: style.textAlign)
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
		// containing height and are treated as auto for now. Tables and their
		// cells grow to fit their content, so for them a height is a minimum.
		if case .px(let fixed) = style.height {
			contentHeight = isTable || isCell ? max(contentHeight, fixed) : fixed
		}

		box.height = contentHeight + paddingTop + paddingBottom + border.top + border.bottom
		return box.height
	}

	/// How far right of its left margin a block sits within its containing
	/// block when it leaves `freeWidth` unused: auto margins share that space
	/// out — both centring the box, one pushing it to the other side — and
	/// failing those, a legacy `-webkit-*` alignment of the container (HTML's
	/// `<center>` and `align` attributes) aligns the box the same way.
	private func horizontalOffset(freeWidth: Double, margin: Edges<Length>, containerAlign: TextAlign) -> Double {
		guard freeWidth > 0 else { return 0 }
		switch (margin.left == .auto, margin.right == .auto) {
		case (true, true): return freeWidth / 2
		case (true, false): return freeWidth
		case (false, true): return 0
		case (false, false):
			switch containerAlign {
			case .webkitCenter: return freeWidth / 2
			case .webkitRight: return freeWidth
			default: return 0
			}
		}
	}

	// MARK: - Replaced images

	/// The used content size of a replaced image: its CSS `width` and `height`
	/// (only pixel heights; percentage widths need `containingWidth`), else the
	/// intrinsic size, keeping the aspect ratio when only one is given — then
	/// clamped by `min-width`/`max-width`, which carry an auto height along.
	/// That last step is what keeps the ubiquitous `max-width: 100%` email image
	/// inside its column.
	///
	/// With no containing width (intrinsic sizing), percentages act as `auto`.
	func replacedSize(of image: DecodedImage, style: ComputedStyle, containingWidth: Double?) -> (width: Double, height: Double) {
		func resolve(_ length: Length) -> Double? {
			switch length {
			case .px(let value): return value
			case .percent(let percent): return containingWidth.map { percent / 100 * $0 }
			case .auto: return nil
			}
		}
		let intrinsicWidth = max(1.0, Double(image.width))
		let intrinsicHeight = max(1.0, Double(image.height))
		let cssWidth = resolve(style.width)
		let cssHeight: Double? = { if case .px(let value) = style.height { return value }; return nil }()
		var width: Double
		var height: Double
		switch (cssWidth, cssHeight) {
		case let (specifiedWidth?, specifiedHeight?): width = specifiedWidth; height = specifiedHeight
		case let (specifiedWidth?, nil): width = specifiedWidth; height = intrinsicHeight * (specifiedWidth / intrinsicWidth)
		case let (nil, specifiedHeight?): height = specifiedHeight; width = intrinsicWidth * (specifiedHeight / intrinsicHeight)
		case (nil, nil): width = intrinsicWidth; height = intrinsicHeight
		}

		let maximum = style.maxWidth.flatMap(resolve) ?? .infinity
		let clamped = max(resolve(style.minWidth) ?? 0, min(width, maximum))
		if clamped != width {
			if cssHeight == nil { height *= clamped / max(width, 1) }
			width = clamped
		}
		return (max(0, width), max(0, height))
	}

	/// The margin box of a replaced image placed inline, and where its content
	/// box sits inside that.
	func replacedBoxMetrics(of image: DecodedImage, style: ComputedStyle, containingWidth: Double?) -> ReplacedBoxMetrics {
		let basis = containingWidth ?? 0
		func edge(_ margin: Length, _ padding: Length, _ border: Double) -> Double {
			(margin.resolved(percentageBasis: basis) ?? 0) + (padding.resolved(percentageBasis: basis) ?? 0) + border
		}
		let border = Edges(
			top: style.borderStyle.top.isVisible ? style.borderWidth.top : 0,
			right: style.borderStyle.right.isVisible ? style.borderWidth.right : 0,
			bottom: style.borderStyle.bottom.isVisible ? style.borderWidth.bottom : 0,
			left: style.borderStyle.left.isVisible ? style.borderWidth.left : 0)
		let left = edge(style.margin.left, style.padding.left, border.left)
		let right = edge(style.margin.right, style.padding.right, border.right)
		let top = edge(style.margin.top, style.padding.top, border.top)
		let bottom = edge(style.margin.bottom, style.padding.bottom, border.bottom)
		let size = replacedSize(of: image, style: style, containingWidth: containingWidth)
		return ReplacedBoxMetrics(width: left + size.width + right, height: top + size.height + bottom,
		                          contentX: left, contentY: top, contentWidth: size.width, contentHeight: size.height)
	}

	/// Whether a replaced image gives up its width when its container is
	/// squeezed: percentage sizes make its min-content contribution zero.
	func isCompressibleReplaced(_ style: ComputedStyle) -> Bool {
		if case .percent = style.width { return true }
		if case .percent? = style.maxWidth { return true }
		return false
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

		// Row heights come from cells confined to a single row, and from a pixel
		// height on the row itself, which like a cell's is a minimum.
		var rowHeights = rows.map { row -> Double in
			if case .px(let height) = row.box.style.height { return height }
			return 0
		}
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

	/// What a table's columns need and ask for, from their cells.
	private struct ColumnMetrics {
		/// The narrowest each column can be without overflowing (min-content).
		var minimum: [Double]
		/// What each column takes when nothing in it wraps (max-content).
		var maximum: [Double]
		/// The border-box width a cell set in pixels, per column.
		var fixed: [Double?]
		/// The percentage width a cell set, per column.
		var percent: [Double?]

		/// The width each column would like: what a cell set in pixels, or its
		/// percentage of `tableWidth`, else its max-content width — and never less
		/// than its min-content width. A set width wins over longer content, which
		/// then wraps, as in browsers. Without a table width (intrinsic sizing) a
		/// percentage column asks for its content.
		func preferred(tableWidth: Double?) -> [Double] {
			minimum.indices.map { column in
				if let fixed = fixed[column] { return max(minimum[column], fixed) }
				if let percent = percent[column], let tableWidth { return max(minimum[column], percent / 100 * tableWidth) }
				return max(minimum[column], maximum[column])
			}
		}

		/// The columns no cell gave a width, which take a table's spare width.
		var isAuto: [Bool] {
			minimum.indices.map { fixed[$0] == nil && percent[$0] == nil }
		}
	}

	private func columnMetrics(_ placements: [CellPlacement], columnCount: Int, spacing: Double) -> ColumnMetrics {
		var metrics = ColumnMetrics(minimum: [Double](repeating: 0, count: columnCount),
		                            maximum: [Double](repeating: 0, count: columnCount),
		                            fixed: [Double?](repeating: nil, count: columnCount),
		                            percent: [Double?](repeating: nil, count: columnCount))

		// Establish ordinary columns first. Colspan requirements are applied after
		// that so they only add the width not already supplied by their columns.
		for placement in placements where placement.colspan == 1 {
			let cell = placement.cell
			let column = placement.column
			metrics.minimum[column] = max(metrics.minimum[column], minContentWidth(of: cell))
			metrics.maximum[column] = max(metrics.maximum[column], maxContentWidth(of: cell))
			switch cell.style.width {
			case .px(let width) where width > 0:
				let border = cell.usedBorder
				let padding = (cell.style.padding.left.resolved(percentageBasis: 0) ?? 0)
					+ (cell.style.padding.right.resolved(percentageBasis: 0) ?? 0)
				metrics.fixed[column] = max(metrics.fixed[column] ?? 0, width + padding + border.left + border.right)
			case .percent(let percent) where percent > 0:
				metrics.percent[column] = max(metrics.percent[column] ?? 0, percent)
			default:
				break
			}
		}
		let spanning = placements.filter { $0.colspan > 1 }.sorted { $0.colspan < $1.colspan }
		func widen(_ widths: inout [Double], measuring measure: (BlockBox) -> Double) {
			for placement in spanning {
				let columns = placement.column ..< min(placement.column + placement.colspan, columnCount)
				let current = widths[columns].reduce(0, +) + Double(columns.count - 1) * spacing
				let deficit = measure(placement.cell) - current
				if deficit > 0 {
					let share = deficit / Double(columns.count)
					for column in columns { widths[column] += share }
				}
			}
		}
		widen(&metrics.minimum, measuring: minContentWidth(of:))
		widen(&metrics.maximum, measuring: maxContentWidth(of:))
		return metrics
	}

	/// Approximate CSS automatic table layout with each cell's intrinsic widths.
	/// A table wider than its columns would like gives the spare width to the
	/// columns no cell set a width for. If the preferred widths do not fit,
	/// distribute the reduction over each column's max-content slack. If the
	/// minimum grid itself does not fit, keep narrower columns at min-content
	/// and cap the widest columns instead.
	private func tableColumnWidths(_ placements: [CellPlacement], columnCount: Int,
	                               availableWidth: Double, spacing: Double) -> [Double] {
		let columns = columnMetrics(placements, columnCount: columnCount, spacing: spacing)
		let preferred = columns.preferred(tableWidth: availableWidth)
		if preferred.reduce(0, +) < availableWidth {
			return TableColumnWidths.expand(preferred, growable: columns.isAuto, to: availableWidth)
		}
		return TableColumnWidths.fit(preferred: preferred, minimum: columns.minimum, to: availableWidth)
	}

	/// The narrowest and the preferred content width of a table's grid, cell
	/// spacing included.
	private func tableIntrinsicContentWidths(_ table: BlockBox) -> (minimum: Double, preferred: Double) {
		let grid = tableGrid(for: table)
		guard grid.columnCount > 0 else { return (0, 0) }
		let spacing = table.style.borderCollapse == .collapse ? 0 : table.style.borderSpacing.horizontal
		let columns = columnMetrics(grid.placements, columnCount: grid.columnCount, spacing: spacing)
		let gaps = Double(grid.columnCount + 1) * spacing
		return (columns.minimum.reduce(0, +) + gaps, columns.preferred(tableWidth: nil).reduce(0, +) + gaps)
	}

	/// A table's content width under automatic layout (CSS 2.1 §17.5.2.2): the
	/// width it was given, else as wide as its columns would like within the
	/// space available — shrink-to-fit, as browsers size a table without a
	/// width — and never narrower than its columns can go, as long as that
	/// fits. A grid that cannot fit at all is held to the available width; its
	/// widest columns then shrink rather than run off the page.
	private func tableContentWidth(_ table: BlockBox, specifiedWidth: Double?, availableWidth: Double,
	                               minimumWidth: Double, maximumWidth: Double?) -> Double {
		let intrinsic = tableIntrinsicContentWidths(table)
		var width = specifiedWidth ?? min(intrinsic.preferred, availableWidth)
		if let maximumWidth { width = min(width, maximumWidth) }
		return max(0, width, minimumWidth, min(intrinsic.minimum, availableWidth))
	}

	private enum IntrinsicSize {
		/// Broken at every ordinary soft wrap opportunity.
		case minimum
		/// With nothing wrapped.
		case maximum
	}

	/// The border-box width a block needs when none of its inline content wraps.
	private func maxContentWidth(of box: BlockBox) -> Double {
		intrinsicWidth(of: box, .maximum)
	}

	/// The border-box width needed at ordinary soft wrap opportunities. Emergency
	/// opportunities from `overflow-wrap: break-word` deliberately do not count;
	/// `anywhere` and `word-break: break-all` do count.
	private func minContentWidth(of box: BlockBox) -> Double {
		intrinsicWidth(of: box, .minimum)
	}

	private func intrinsicWidth(of box: BlockBox, _ size: IntrinsicSize) -> Double {
		let key = IntrinsicWidthKey(box: ObjectIdentifier(box), size: size)
		if let measured = intrinsicWidths[key] { return measured }
		let width = measureIntrinsicWidth(of: box, size)
		intrinsicWidths[key] = width
		return width
	}

	private func measureIntrinsicWidth(of box: BlockBox, _ size: IntrinsicSize) -> Double {
		let style = box.style
		let border = box.usedBorder
		let padding = (style.padding.left.resolved(percentageBasis: 0) ?? 0)
			+ (style.padding.right.resolved(percentageBasis: 0) ?? 0)
		let margins = (style.margin.left.resolved(percentageBasis: 0) ?? 0)
			+ (style.margin.right.resolved(percentageBasis: 0) ?? 0)
		let paddingAndBorder = border.left + border.right + padding

		var contentWidth: Double
		if let image = box.image {
			contentWidth = size == .minimum && isCompressibleReplaced(style)
				? 0 : replacedSize(of: image, style: style, containingWidth: nil).width
		} else if style.display == .table {
			let widths = tableIntrinsicContentWidths(box)
			contentWidth = size == .minimum ? widths.minimum : widths.preferred
		} else if box.establishesInlineContext {
			var tokens: [InlineToken] = []
			if size == .minimum {
				for child in box.children { collectInline(child, into: &tokens, href: nil, decorations: TextDecorationRuns()) }
				contentWidth = minContentWidth(of: tokens, textIndent: style.textIndent)
			} else {
				let source = ObjectIdentifier(box)
				let decorations = TextDecorationRuns(
					underline: style.underline ? TextDecorationRun(source: source, style: style) : nil,
					lineThrough: style.lineThrough ? TextDecorationRun(source: source, style: style) : nil)
				for child in box.children {
					collectInline(child, into: &tokens, href: nil, decorations: decorations)
				}
				contentWidth = maxContentWidth(of: tokens, textIndent: style.textIndent)
			}
		} else {
			contentWidth = box.children.compactMap { $0 as? BlockBox }.map { intrinsicWidth(of: $0, size) }.max() ?? 0
		}
		// A pixel width is what the box contributes, unless its content needs
		// more. A table's width covers its border box; a cell's width sizes its
		// column instead (see `columnMetrics`).
		if style.display != .tableCell, case .px(let width) = style.width {
			contentWidth = max(contentWidth, style.display == .table ? width - paddingAndBorder : width)
		}
		if case .px(let minimum) = style.minWidth {
			contentWidth = max(contentWidth, minimum)
		}
		return contentWidth + paddingAndBorder + margins
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
			case .image(let image, let style, _):
				if hasContent, let space = pendingSpace {
					lineWidth += fonts.font(for: space).width(of: " ", size: space.fontSize) + space.wordSpacing
				}
				lineWidth += replacedBoxMetrics(of: image, style: style, containingWidth: nil).width
				hasContent = true
				pendingSpace = nil
			case .word(let word, let style, _, _):
				if hasContent, let space = pendingSpace {
					lineWidth += fonts.font(for: space).width(of: " ", size: space.fontSize) + space.wordSpacing
				}
				lineWidth += inlineTextWidth(word, style: style)
				hasContent = true
				pendingSpace = nil
			}
		}
		return max(maximum, lineWidth)
	}

	private func minContentWidth(of tokens: [InlineToken], textIndent: Double) -> Double {
		var maximum = 0.0
		var runWidth = 0.0
		var hasContent = false
		var isFirstContent = true
		var pendingSpace: ComputedStyle?
		func finishRun() { maximum = max(maximum, runWidth); runWidth = 0 }
		func beginContent() {
			if isFirstContent {
				runWidth += textIndent
				isFirstContent = false
			}
			hasContent = true
		}
		func prepareContent(wrapping wraps: Bool) {
			if wraps, hasContent {
				finishRun()
				hasContent = false
			} else if let space = pendingSpace {
				runWidth += fonts.font(for: space).width(of: " ", size: space.fontSize) + space.wordSpacing
			}
			pendingSpace = nil
		}
		for token in tokens {
			switch token {
			case .space(let style):
				if hasContent { pendingSpace = style }
			case .forcedBreak:
				finishRun()
				hasContent = false
				pendingSpace = nil
			case .checkbox(_, let style):
				prepareContent(wrapping: style.whiteSpace.wraps)
				beginContent()
				runWidth += (style.margin.left.resolved(percentageBasis: 0) ?? 0)
					+ style.fontSize
					+ (style.margin.right.resolved(percentageBasis: 0) ?? 0)
			case .image(let image, let style, _):
				// A line may break on either side of a replaced image, so it is a
				// run of its own.
				finishRun()
				pendingSpace = nil
				beginContent()
				let metrics = replacedBoxMetrics(of: image, style: style, containingWidth: nil)
				runWidth += isCompressibleReplaced(style) ? metrics.width - metrics.contentWidth : metrics.width
				finishRun()
				hasContent = false
			case .word(let word, let style, _, _):
				prepareContent(wrapping: style.whiteSpace.wraps)
				beginContent()
				for (index, width) in minContentSegments(of: word, style: style).enumerated() {
					if index > 0 { finishRun() }
					runWidth += width
				}
			}
		}
		finishRun()
		return maximum
	}

	private func inlineTextWidth(_ text: String, style: ComputedStyle) -> Double {
		fonts.resolveRuns(text, style: style).reduce(0.0) { width, run in
			width + run.font.width(of: run.text, size: style.fontSize)
				+ style.letterSpacing * Double(run.text.unicodeScalars.count)
		}
	}

	private func minContentSegments(of word: String, style: ComputedStyle) -> [Double] {
		guard style.whiteSpace.wraps else { return [inlineTextWidth(word, style: style)] }
		if style.wordBreak == .breakAll || style.overflowWrap == .anywhere {
			return word.map { inlineTextWidth(String($0), style: style) }
		}

		let breaks = preferredLineBreakOffsets(in: word).sorted()
		guard !breaks.isEmpty else { return [inlineTextWidth(word, style: style)] }
		var widths: [Double] = []
		var start = word.startIndex
		for offset in breaks {
			let end = String.Index(utf16Offset: offset, in: word)
			widths.append(inlineTextWidth(String(word[start ..< end]), style: style))
			start = end
		}
		widths.append(inlineTextWidth(String(word[start...]), style: style))
		return widths
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
