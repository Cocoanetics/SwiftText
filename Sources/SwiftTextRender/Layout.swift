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
		layoutBlock(root, containingWidth: contentWidth, marginX: originX, marginY: originY)
	}

	/// Lay out a block whose margin box starts at `(marginX, marginY)`. Sets the
	/// box's border-box geometry and returns its margin-box height.
	private func layoutBlock(_ box: BlockBox, containingWidth: Double, marginX: Double, marginY: Double) -> Double {
		let style = box.style
		let basis = containingWidth

		let marginLeft = style.margin.left.resolved(percentageBasis: basis) ?? 0
		let marginRight = style.margin.right.resolved(percentageBasis: basis) ?? 0
		let marginTop = style.margin.top.resolved(percentageBasis: basis) ?? 0
		let marginBottom = style.margin.bottom.resolved(percentageBasis: basis) ?? 0

		let border = box.usedBorder
		let paddingLeft = style.padding.left.resolved(percentageBasis: basis) ?? 0
		let paddingRight = style.padding.right.resolved(percentageBasis: basis) ?? 0
		let paddingTop = style.padding.top.resolved(percentageBasis: basis) ?? 0
		let paddingBottom = style.padding.bottom.resolved(percentageBasis: basis) ?? 0

		let horizontalExtras = marginLeft + marginRight + border.left + border.right + paddingLeft + paddingRight
		let explicitWidth = style.width.resolved(percentageBasis: basis)
		let contentWidth = max(0, explicitWidth ?? (containingWidth - horizontalExtras))
		let borderBoxWidth = contentWidth + paddingLeft + paddingRight + border.left + border.right

		box.x = marginX + marginLeft
		box.y = marginY + marginTop
		box.width = borderBoxWidth

		let contentX = box.x + border.left + paddingLeft
		let contentTop = box.y + border.top + paddingTop

		var contentHeight: Double
		if box.establishesInlineContext {
			contentHeight = layoutInline(box, contentWidth: contentWidth, contentX: contentX, contentTop: contentTop)
		} else {
			var cursorY = contentTop
			for child in box.children {
				guard let childBlock = child as? BlockBox else { continue }
				cursorY += layoutBlock(childBlock, containingWidth: contentWidth, marginX: contentX, marginY: cursorY)
			}
			contentHeight = cursorY - contentTop
		}

		// Only explicit pixel heights are honored; percentages need a resolved
		// containing height and are treated as auto for now.
		if case .px(let fixed) = style.height {
			contentHeight = fixed
		}

		box.height = contentHeight + paddingTop + paddingBottom + border.top + border.bottom
		return marginTop + box.height + marginBottom
	}

	// MARK: - Inline layout

	private enum InlineToken {
		case word(String, ComputedStyle)
		case space(ComputedStyle)
	}

	/// Lay out the inline content of `box` into lines. Returns the content height.
	private func layoutInline(_ box: BlockBox, contentWidth: Double, contentX: Double, contentTop: Double) -> Double {
		var tokens: [InlineToken] = []
		for child in box.children {
			collectInline(child, into: &tokens)
		}

		var lines: [LineBox] = []
		var fragments: [TextFragment] = []
		var penX = 0.0
		var pendingSpace: ComputedStyle? = nil
		var lineTop = contentTop

		func finishLine() {
			guard !fragments.isEmpty else { pendingSpace = nil; return }
			let lineHeight = fragments.map { $0.style.resolvedLineHeight() }.max() ?? 0
			let ascent = fragments.map { fonts.font(for: $0.style).ascent(size: $0.style.fontSize) }.max() ?? 0
			let descent = fragments.map { fonts.font(for: $0.style).descent(size: $0.style.fontSize) }.max() ?? 0
			// Center the text box within the line height (half-leading).
			let baselineFromTop = ascent + (lineHeight - ascent - descent) / 2

			let line = LineBox()
			line.x = contentX
			line.y = lineTop
			line.width = penX
			line.height = lineHeight
			line.baseline = baselineFromTop
			line.fragments = fragments.map { fragment in
				var positioned = fragment
				positioned.x += contentX
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
			case .word(let word, let style):
				let font = fonts.font(for: style)
				let wordWidth = font.width(of: word, size: style.fontSize)
				let spaceWidth = pendingSpace.map { fonts.font(for: $0).width(of: " ", size: $0.fontSize) } ?? 0

				let wraps = style.whiteSpace.wraps
				if wraps && !fragments.isEmpty && penX + spaceWidth + wordWidth > contentWidth {
					finishLine()
				} else if !fragments.isEmpty, let space = pendingSpace {
					penX += fonts.font(for: space).width(of: " ", size: space.fontSize)
					pendingSpace = nil
				}

				let fragment = TextFragment(text: word, style: style, x: penX, y: 0, width: wordWidth, baseline: 0)
				fragments.append(fragment)
				penX += wordWidth
			}
		}
		finishLine()

		box.lines = lines
		return lineTop - contentTop
	}

	private func collectInline(_ box: Box, into tokens: inout [InlineToken]) {
		if let text = box as? TextBox {
			let style = text.style
			let content = style.whiteSpace.collapsesWhitespace ? collapseWhitespace(text.text) : text.text
			var word = ""
			for character in content {
				if character == " " || character == "\t" || character == "\n" {
					if !word.isEmpty { tokens.append(.word(word, style)); word = "" }
					tokens.append(.space(style))
				} else {
					word.append(character)
				}
			}
			if !word.isEmpty { tokens.append(.word(word, style)) }
		} else if let inline = box as? InlineBox {
			for child in inline.children { collectInline(child, into: &tokens) }
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
