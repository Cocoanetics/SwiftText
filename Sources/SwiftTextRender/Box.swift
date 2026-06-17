//  Box.swift
//  SwiftTextRender
//
//  The box tree: the intermediate representation between styled DOM and layout,
//  following CSS's block/inline box model (a simplified version of WeasyPrint's
//  formatting_structure).

import Foundation
import SwiftTextCSS

/// Base class for all boxes. Geometry fields are filled during layout and refer
/// to the border-box top-left corner in absolute page coordinates.
public class Box {
	/// The computed style governing this box.
	public let style: ComputedStyle
	/// The source element this box came from, if any (nil for anonymous/text).
	/// A strong reference: the box tree keeps its styled elements alive (elements
	/// do not reference boxes, so there is no cycle).
	public internal(set) var element: StyledElement?

	// Layout results (border-box geometry).
	public var x: Double = 0
	public var y: Double = 0
	public var width: Double = 0
	public var height: Double = 0

	init(style: ComputedStyle) {
		self.style = style
	}

	/// Used (drawn) border widths, accounting for `border-style: none`.
	public var usedBorder: Edges<Double> {
		Edges(
			top: style.borderStyle.top.isVisible ? style.borderWidth.top : 0,
			right: style.borderStyle.right.isVisible ? style.borderWidth.right : 0,
			bottom: style.borderStyle.bottom.isVisible ? style.borderWidth.bottom : 0,
			left: style.borderStyle.left.isVisible ? style.borderWidth.left : 0)
	}
}

/// A block-level box that contains either block-level children or an inline
/// formatting context (a run of inline-level children).
public final class BlockBox: Box {
	public var children: [Box] = []
	/// Whether this box was generated to wrap inline content (no element).
	public let isAnonymous: Bool
	/// Line boxes produced by inline layout, when this box establishes an inline
	/// formatting context.
	public var lines: [LineBox] = []
	/// For `display: list-item` boxes, the marker text (e.g. "•" or "3.").
	public var marker: String?

	init(style: ComputedStyle, isAnonymous: Bool = false) {
		self.isAnonymous = isAnonymous
		super.init(style: style)
	}

	/// Whether this block's children are all inline-level (an inline context).
	public var establishesInlineContext: Bool {
		!children.isEmpty && children.allSatisfy { $0 is InlineBox || $0 is TextBox }
	}
}

/// An inline-level container (e.g. `<span>`, `<em>`).
public final class InlineBox: Box {
	public var children: [Box] = []

	init(style: ComputedStyle, children: [Box] = []) {
		self.children = children
		super.init(style: style)
	}
}

/// A run of text with a single style.
public final class TextBox: Box {
	public var text: String

	init(style: ComputedStyle, text: String) {
		self.text = text
		super.init(style: style)
	}
}

/// One laid-out line within an inline formatting context.
public final class LineBox {
	/// Positioned text fragments on this line, in visual order.
	public var fragments: [TextFragment] = []
	public var x: Double = 0
	public var y: Double = 0
	public var width: Double = 0
	public var height: Double = 0
	/// Distance from the line's top to the text baseline.
	public var baseline: Double = 0

	public init() {}
}

/// A shaped run of text positioned on a line.
public struct TextFragment {
	public let text: String
	public let style: ComputedStyle
	public var x: Double
	public var y: Double
	public var width: Double
	/// Distance from the fragment's top to its baseline.
	public var baseline: Double

	public init(text: String, style: ComputedStyle, x: Double, y: Double, width: Double, baseline: Double) {
		self.text = text
		self.style = style
		self.x = x
		self.y = y
		self.width = width
		self.baseline = baseline
	}
}
