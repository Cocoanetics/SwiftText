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

		// Place a list-item marker to the left of the first line, in the padding
		// reserved by the list's UA padding-left.
		if let marker = box.marker, let line = firstLineBox(in: box) {
			let font = fonts.font(for: box.style)
			let markerWidth = font.width(of: marker, size: box.style.fontSize)
			let gap = font.width(of: " ", size: box.style.fontSize)
			let fragment = TextFragment(text: marker, style: box.style,
			                            x: contentX - markerWidth - gap, y: line.y,
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

	/// Lay out a `display: table` box as a simple equal-column grid. Each cell is
	/// laid out as a block in its column; the row height is the tallest cell.
	/// Column/row spans and content-based column sizing are not modeled yet.
	private func layoutTable(_ table: BlockBox, contentWidth: Double, contentX: Double, contentTop: Double) -> Double {
		let rows = collectTableRows(table)
		let columnCount = rows.map(\.cells.count).max() ?? 0
		guard columnCount > 0 else { return 0 }

		let spacing = 2.0 // border-spacing (UA default)
		let columnWidth = max(0, (contentWidth - Double(columnCount + 1) * spacing) / Double(columnCount))

		var y = contentTop + spacing
		for row in rows {
			let rowTop = y
			var x = contentX + spacing
			var rowHeight = 0.0
			for cell in row.cells {
				let height = layoutBlock(cell, containingWidth: columnWidth, marginX: x, borderBoxTop: rowTop)
				rowHeight = max(rowHeight, height)
				x += columnWidth + spacing
			}
			// Stretch every cell to the row height so backgrounds/borders fill it.
			for cell in row.cells { cell.height = rowHeight }
			row.box.x = contentX
			row.box.y = rowTop
			row.box.width = contentWidth
			row.box.height = rowHeight
			y = rowTop + rowHeight + spacing
		}
		return y - contentTop
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

		var lines: [LineBox] = []
		var fragments: [TextFragment] = []
		var penX = 0.0
		var pendingSpace: ComputedStyle? = nil
		var lineTop = contentTop

		func finishLine(isLast: Bool) {
			guard !fragments.isEmpty else { pendingSpace = nil; return }
			let lineHeight = fragments.map { $0.style.resolvedLineHeight() }.max() ?? 0
			let ascent = fragments.map { fonts.font(for: $0.style).ascent(size: $0.style.fontSize) }.max() ?? 0
			let descent = fragments.map { fonts.font(for: $0.style).descent(size: $0.style.fontSize) }.max() ?? 0
			// Center the text box within the line height (half-leading).
			let baselineFromTop = ascent + (lineHeight - ascent - descent) / 2

			// Horizontal alignment within the content width.
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

			let line = LineBox()
			line.x = contentX
			line.y = lineTop
			line.width = penX + perGap * Double(gaps)
			line.height = lineHeight
			line.baseline = baselineFromTop
			line.fragments = fragments.enumerated().map { index, fragment in
				var positioned = fragment
				positioned.x += contentX + offset + perGap * Double(index)
				positioned.y = lineTop
				positioned.baseline = lineTop + baselineFromTop
				return positioned
			}
			lines.append(line)

			lineTop += lineHeight
			fragments = []
			penX = 0
			pendingSpace = nil
		}

		for token in tokens {
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
			case .word(let word, let style, let href):
				let font = fonts.font(for: style)
				let wordWidth = font.width(of: word, size: style.fontSize)
				let spaceWidth = pendingSpace.map { fonts.font(for: $0).width(of: " ", size: $0.fontSize) } ?? 0

				let wraps = style.whiteSpace.wraps
				if wraps && !fragments.isEmpty && penX + spaceWidth + wordWidth > contentWidth {
					finishLine(isLast: false)
				} else if !fragments.isEmpty, let space = pendingSpace {
					penX += fonts.font(for: space).width(of: " ", size: space.fontSize)
					pendingSpace = nil
				}

				let fragment = TextFragment(text: word, style: style, x: penX, y: 0, width: wordWidth, baseline: 0, href: href)
				fragments.append(fragment)
				penX += wordWidth
			}
		}
		finishLine(isLast: true)

		box.lines = lines
		return lineTop - contentTop
	}

	private func collectInline(_ box: Box, into tokens: inout [InlineToken], href: String?) {
		if let text = box as? TextBox {
			let style = text.style
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
