//  ComputedStyle.swift
//  SwiftTextCSS
//
//  The typed result of the cascade: every property the layout engine needs,
//  resolved to absolute units where possible. Mirrors the subset of
//  WeasyPrint's computed values required for block and inline layout.

import Foundation

/// A CSS length, with absolute units already resolved to CSS pixels.
public enum Length: Equatable, Sendable {
	case px(Double)
	case percent(Double)
	case auto

	/// Resolve to pixels given a percentage basis, or `nil` for `auto`.
	public func resolved(percentageBasis: Double) -> Double? {
		switch self {
		case .px(let value): return value
		case .percent(let value): return value / 100 * percentageBasis
		case .auto: return nil
		}
	}
}

/// The four edges of a box.
public struct Edges<Value: Equatable & Sendable>: Equatable, Sendable {
	public var top: Value
	public var right: Value
	public var bottom: Value
	public var left: Value

	public init(top: Value, right: Value, bottom: Value, left: Value) {
		self.top = top
		self.right = right
		self.bottom = bottom
		self.left = left
	}

	public init(_ all: Value) {
		self.init(top: all, right: all, bottom: all, left: all)
	}
}

public enum Display: Equatable, Sendable {
	case none, inline, block, inlineBlock, listItem
	case table, tableRow, tableCell, tableRowGroup, tableHeaderGroup, tableFooterGroup
	case tableColumn, tableColumnGroup, tableCaption
	case flex, inlineFlex, grid, inlineGrid
	case other(String)

	/// Whether this display generates a block-level box.
	public var isBlockLevel: Bool {
		switch self {
		case .block, .listItem, .table, .flex, .grid: return true
		default: return false
		}
	}
}

public enum FontStyle: String, Equatable, Sendable {
	case normal, italic, oblique
}

public enum TextAlign: String, Equatable, Sendable {
	case start, end, left, right, center, justify
}

public enum Direction: String, Equatable, Sendable {
	case ltr, rtl
	public var isRTL: Bool { self == .rtl }
}

public enum VerticalAlign: String, Equatable, Sendable {
	case baseline, top, middle, bottom, sub
	case textTop = "text-top"
	case textBottom = "text-bottom"
}

public enum WhiteSpace: Equatable, Sendable {
	case normal, pre, nowrap, preWrap, preLine

	/// Whether runs of whitespace collapse to a single space.
	public var collapsesWhitespace: Bool {
		switch self {
		case .normal, .nowrap: return true
		case .pre, .preWrap, .preLine: return false
		}
	}

	/// Whether lines may wrap at soft break opportunities.
	public var wraps: Bool {
		switch self {
		case .normal, .preWrap, .preLine: return true
		case .pre, .nowrap: return false
		}
	}
}

public enum ListStyleType: String, Equatable, Sendable {
	case disc, circle, square, none
	case decimal
	case lowerAlpha = "lower-alpha"
	case upperAlpha = "upper-alpha"
	case lowerRoman = "lower-roman"
	case upperRoman = "upper-roman"
	/// Arabic-Indic digits (٠١٢…), as used by `list-style-type: arabic-indic`.
	case arabicIndic = "arabic-indic"

	/// Whether the marker is an ordinal counter rather than a bullet.
	public var isOrdered: Bool {
		switch self {
		case .decimal, .lowerAlpha, .upperAlpha, .lowerRoman, .upperRoman, .arabicIndic: return true
		default: return false
		}
	}
}

public enum BorderStyle: String, Equatable, Sendable {
	case none, hidden, solid, dashed, dotted, double, groove, ridge, inset, outset

	/// Whether a border with this style is actually drawn (and reserves width).
	public var isVisible: Bool {
		self != .none && self != .hidden
	}
}

/// Line height: a multiplier of font-size, an absolute length, or `normal`.
public enum LineHeight: Equatable, Sendable {
	case normal
	case number(Double)
	case length(Double)

	/// Resolve to pixels for the given font size (`normal` ≈ 1.2).
	public func resolved(fontSize: Double) -> Double {
		switch self {
		case .normal: return fontSize * 1.2
		case .number(let factor): return fontSize * factor
		case .length(let value): return value
		}
	}
}

/// The fully resolved style of one element.
public struct ComputedStyle: Equatable, Sendable {
	// Inherited properties.
	public var color: RGBA
	public var fontFamily: [String]
	public var fontSize: Double
	public var fontStyle: FontStyle
	public var fontWeight: Int
	public var lineHeight: LineHeight
	public var textAlign: TextAlign
	public var whiteSpace: WhiteSpace
	/// Whether text is underlined (`text-decoration: underline`).
	public var underline: Bool
	/// Whether text has a line through it (`text-decoration: line-through`).
	public var lineThrough: Bool
	/// Extra space between characters in pixels (`letter-spacing`).
	public var letterSpacing: Double
	/// Extra space added to each space character in pixels (`word-spacing`).
	public var wordSpacing: Double
	/// The list marker style (`list-style-type`).
	public var listStyleType: ListStyleType
	/// First-line indentation in pixels (`text-indent`).
	public var textIndent: Double
	/// Base writing direction (`direction`; also set by the `dir` attribute).
	public var direction: Direction

	// Non-inherited properties.
	public var display: Display
	/// Vertical alignment (applied to table cells; `super` is omitted).
	public var verticalAlign: VerticalAlign
	public var backgroundColor: RGBA?
	public var margin: Edges<Length>
	public var padding: Edges<Length>
	public var borderWidth: Edges<Double>
	public var borderStyle: Edges<BorderStyle>
	public var borderColor: Edges<RGBA>
	public var width: Length
	public var height: Length

	/// Pixel line height for this style's font size.
	public func resolvedLineHeight() -> Double {
		lineHeight.resolved(fontSize: fontSize)
	}

	/// The used border width of an edge: zero unless the edge's style is visible.
	public func usedBorderWidth(_ edge: WritableKeyPath<Edges<Double>, Double>, style edgeStyle: KeyPath<Edges<BorderStyle>, BorderStyle>) -> Double {
		borderStyle[keyPath: edgeStyle].isVisible ? borderWidth[keyPath: edge] : 0
	}

	/// The initial style — the root of inheritance (CSS initial values).
	public static let initial = ComputedStyle(
		color: RGBA(0, 0, 0, 1),
		fontFamily: ["serif"],
		fontSize: 16,
		fontStyle: .normal,
		fontWeight: 400,
		lineHeight: .normal,
		textAlign: .start,
		whiteSpace: .normal,
		underline: false,
		lineThrough: false,
		letterSpacing: 0,
		wordSpacing: 0,
		listStyleType: .disc,
		textIndent: 0,
		direction: .ltr,
		display: .inline,
		verticalAlign: .baseline,
		backgroundColor: nil,
		margin: Edges(.px(0)),
		padding: Edges(.px(0)),
		borderWidth: Edges(0),
		borderStyle: Edges(.none),
		borderColor: Edges(RGBA(0, 0, 0, 1)),
		width: .auto,
		height: .auto)

	/// A fresh style for a child: inherited properties copied from `parent`,
	/// non-inherited properties reset to their initial values.
	public static func inheriting(from parent: ComputedStyle) -> ComputedStyle {
		var style = ComputedStyle.initial
		style.color = parent.color
		style.fontFamily = parent.fontFamily
		style.fontSize = parent.fontSize
		style.fontStyle = parent.fontStyle
		style.fontWeight = parent.fontWeight
		style.lineHeight = parent.lineHeight
		style.textAlign = parent.textAlign
		style.whiteSpace = parent.whiteSpace
		// text-decoration is not formally inherited, but an ancestor's decoration
		// visually spans descendants; propagating it approximates that.
		style.underline = parent.underline
		style.lineThrough = parent.lineThrough
		style.letterSpacing = parent.letterSpacing
		style.wordSpacing = parent.wordSpacing
		style.listStyleType = parent.listStyleType
		style.textIndent = parent.textIndent
		style.direction = parent.direction
		// Initial border color is `currentColor`, i.e. the (inherited) color.
		style.borderColor = Edges(parent.color)
		return style
	}
}
