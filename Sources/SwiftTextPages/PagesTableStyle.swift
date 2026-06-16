import Foundation

/// An sRGB color with straight alpha, components in `0...1` — the iWork `TSP.Color`
/// "model 1" RGB form used for cell fills and strokes.
public struct PagesColor: Equatable, Hashable, Sendable {
	public var red: Float, green: Float, blue: Float, alpha: Float
	public init(red: Float, green: Float, blue: Float, alpha: Float = 1) {
		self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
	}
	/// Convenience for 0–255 component values.
	public init(r: Int, g: Int, b: Int, a: Float = 1) {
		self.init(red: Float(r) / 255, green: Float(g) / 255, blue: Float(b) / 255, alpha: a)
	}
	public static let white = PagesColor(red: 1, green: 1, blue: 1)
	public static let black = PagesColor(red: 0, green: 0, blue: 0)
}

/// Vertical placement of text within a cell — `CellStylePropertiesArchive.vertical_alignment` (#8).
public enum PagesVerticalAlignment: Int32, Equatable, Hashable, Sendable {
	case top = 0, middle = 1, bottom = 2
}

/// One cell edge stroke (border): color + line width in points.
public struct PagesCellBorder: Equatable, Hashable, Sendable {
	public var color: PagesColor
	public var width: Float
	public init(color: PagesColor, width: Float = 1) { self.color = color; self.width = width }
}

/// Per-cell appearance overrides — background fill, vertical alignment, text wrap, and
/// per-edge borders. Realised as a synthesized `TST.CellStyleArchive` (6004) whose
/// `cell_properties` carry these, referenced from the cell via the table's style table.
public struct PagesCellAppearance: Equatable, Hashable, Sendable {
	public var fill: PagesColor?
	public var verticalAlignment: PagesVerticalAlignment?
	public var textWrap: Bool?
	public var topBorder: PagesCellBorder?
	public var rightBorder: PagesCellBorder?
	public var bottomBorder: PagesCellBorder?
	public var leftBorder: PagesCellBorder?

	public init(fill: PagesColor? = nil, verticalAlignment: PagesVerticalAlignment? = nil,
	            textWrap: Bool? = nil, topBorder: PagesCellBorder? = nil, rightBorder: PagesCellBorder? = nil,
	            bottomBorder: PagesCellBorder? = nil, leftBorder: PagesCellBorder? = nil) {
		self.fill = fill; self.verticalAlignment = verticalAlignment; self.textWrap = textWrap
		self.topBorder = topBorder; self.rightBorder = rightBorder
		self.bottomBorder = bottomBorder; self.leftBorder = leftBorder
	}
	/// Sets all four edges to the same border.
	public init(allBorders border: PagesCellBorder, fill: PagesColor? = nil) {
		self.init(fill: fill, topBorder: border, rightBorder: border, bottomBorder: border, leftBorder: border)
	}

	public var isEmpty: Bool { !hasCellProperties && !hasBorders }
	/// Settings carried by a `CellStyleArchive` (style-table) — fill / v-align / wrap.
	var hasCellProperties: Bool { fill != nil || verticalAlignment != nil || textWrap != nil }
	/// Settings carried by the table stroke sidecar — per-edge borders.
	var hasBorders: Bool { topBorder != nil || rightBorder != nil || bottomBorder != nil || leftBorder != nil }
}
