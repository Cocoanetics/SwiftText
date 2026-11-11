//  SVGTree.swift
//  SwiftTextRender
//
//  The normalised form of an SVG: groups with resolved transforms and paths
//  with resolved paint, as the static subset needs it. Shapes are already
//  converted to path segments (arcs and quadratics become cubic Béziers), and
//  presentation attributes, `style` and inheritance are resolved. Emitting
//  PDF content from this tree is `SVGImage`'s job.

import Foundation

struct SVGMatrix: Equatable {
	var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0

	static let identity = SVGMatrix()

	/// The transform that applies `self` first and then `next`.
	func then(_ next: SVGMatrix) -> SVGMatrix {
		SVGMatrix(a: a * next.a + b * next.c, b: a * next.b + b * next.d,
		          c: c * next.a + d * next.c, d: c * next.b + d * next.d,
		          e: e * next.a + f * next.c + next.e, f: e * next.b + f * next.d + next.f)
	}
}

enum SVGPathSegment: Equatable {
	case move(Double, Double)
	case line(Double, Double)
	case cubic(Double, Double, Double, Double, Double, Double)
	case close
}

struct SVGColor: Equatable {
	var red: Double, green: Double, blue: Double
	static let black = SVGColor(red: 0, green: 0, blue: 0)
}

struct SVGFill {
	var color: SVGColor
	var opacity: Double
	var evenOdd: Bool
}

struct SVGStroke {
	var color: SVGColor
	var opacity: Double
	var width: Double
	var cap: Int
	var join: Int
	var miterLimit: Double
	var dashes: [Double]
	var dashOffset: Double
}

struct SVGPath {
	var segments: [SVGPathSegment]
	var fill: SVGFill?
	var stroke: SVGStroke?
}

indirect enum SVGNode {
	/// A group: its transform, and the opacity it is composited with as a whole.
	case group(SVGMatrix, Double, [SVGNode])
	case path(SVGPath)
}

/// A parsed SVG document: its intrinsic size, view box and content.
struct SVGTree {
	enum Align { case none, min, mid, max }

	var width: Double
	var height: Double
	var viewBox: (x: Double, y: Double, width: Double, height: Double)
	var alignX = Align.mid
	var alignY = Align.mid
	var slice = false
	var children: [SVGNode]

	/// The transform from user space (y down) into the `width` × `height`
	/// viewport, honouring `preserveAspectRatio`.
	var viewBoxTransform: SVGMatrix {
		let scaleX = width / viewBox.width
		let scaleY = height / viewBox.height
		guard alignX != .none || alignY != .none else {
			return SVGMatrix(a: scaleX, d: scaleY, e: -viewBox.x * scaleX, f: -viewBox.y * scaleY)
		}
		let scale = slice ? max(scaleX, scaleY) : min(scaleX, scaleY)
		func offset(_ align: Align, free: Double) -> Double {
			switch align {
			case .min, .none: return 0
			case .mid: return free / 2
			case .max: return free
			}
		}
		return SVGMatrix(a: scale, d: scale,
		                 e: offset(alignX, free: width - viewBox.width * scale) - viewBox.x * scale,
		                 f: offset(alignY, free: height - viewBox.height * scale) - viewBox.y * scale)
	}
}

// MARK: - Scanning

/// A scanner over the number-heavy micro-syntaxes of SVG (path data, points,
/// transforms, view boxes), which allow compact forms like `1.5.5` and `-1-2`.
struct SVGScanner {
	let bytes: [UInt8]
	var index = 0

	init(_ text: String) { bytes = Array(text.utf8) }

	var atEnd: Bool { index >= bytes.count }
	var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

	mutating func skipSpaces() {
		while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
	}

	/// Skip whitespace and at most one comma.
	mutating func skipSeparators() {
		skipSpaces()
		if peek == 0x2C { index += 1; skipSpaces() }
	}

	mutating func number() -> Double? {
		skipSpaces()
		let start = index
		var cursor = index
		func digits() -> Int {
			let from = cursor
			while cursor < bytes.count, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 { cursor += 1 }
			return cursor - from
		}
		if cursor < bytes.count, bytes[cursor] == 0x2B || bytes[cursor] == 0x2D { cursor += 1 }
		var count = digits()
		if cursor < bytes.count, bytes[cursor] == 0x2E {
			cursor += 1
			count += digits()
		}
		guard count > 0 else { return nil }
		if cursor < bytes.count, bytes[cursor] == 0x65 || bytes[cursor] == 0x45 {
			var probe = cursor + 1
			if probe < bytes.count, bytes[probe] == 0x2B || bytes[probe] == 0x2D { probe += 1 }
			if probe < bytes.count, bytes[probe] >= 0x30, bytes[probe] <= 0x39 {
				cursor = probe
				_ = digits()
			}
		}
		guard let value = Double(String(decoding: bytes[start ..< cursor], as: UTF8.self)), value.isFinite else { return nil }
		index = cursor
		return value
	}

	/// An arc flag: a single `0` or `1`, which may touch the next number.
	mutating func flag() -> Bool? {
		skipSpaces()
		guard let byte = peek, byte == 0x30 || byte == 0x31 else { return nil }
		index += 1
		return byte == 0x31
	}

	mutating func identifier() -> String {
		skipSpaces()
		let start = index
		while let byte = peek, (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) { index += 1 }
		return String(decoding: bytes[start ..< index], as: UTF8.self)
	}

	/// All numbers in a list, or what could be read before the first error.
	static func numbers(_ text: String) -> [Double] {
		var scanner = SVGScanner(text)
		var values: [Double] = []
		scanner.skipSeparators()
		while let value = scanner.number() {
			values.append(value)
			scanner.skipSeparators()
		}
		return values
	}
}

// MARK: - Path data

enum SVGPathData {

	/// Parse `d` into absolute segments. Like a browser, keep everything up to
	/// the first error.
	static func parse(_ text: String) -> [SVGPathSegment] {
		var scanner = SVGScanner(text)
		var segments: [SVGPathSegment] = []
		var x = 0.0, y = 0.0
		var startX = 0.0, startY = 0.0
		var lastControl: (Double, Double)?
		var lastQuad: (Double, Double)?
		var command: UInt8 = 0
		var first = true

		scanner.skipSpaces()
		while !scanner.atEnd {
			if let byte = scanner.peek, (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) {
				command = byte
				scanner.index += 1
			} else if command == 0 || command == 0x5A || command == 0x7A {
				break // numbers without a command, or after Z
			}
			if first {
				guard command == 0x4D || command == 0x6D else { break }
				first = false
			}
			let relative = command >= 0x61
			let upper = relative ? command - 0x20 : command
			let ox = relative ? x : 0, oy = relative ? y : 0
			var wasCubic = false, wasQuad = false

			switch upper {
			case 0x5A: // Z
				segments.append(.close)
				x = startX; y = startY
			case 0x4D: // M
				guard let nx = scanner.number() else { return segments }
				scanner.skipSeparators()
				guard let ny = scanner.number() else { return segments }
				x = ox + nx; y = oy + ny
				startX = x; startY = y
				segments.append(.move(x, y))
				command = relative ? 0x6C : 0x4C // implicit repeats are lineto
			case 0x4C: // L
				guard let nx = scanner.number() else { return segments }
				scanner.skipSeparators()
				guard let ny = scanner.number() else { return segments }
				x = ox + nx; y = oy + ny
				segments.append(.line(x, y))
			case 0x48: // H
				guard let nx = scanner.number() else { return segments }
				x = ox + nx
				segments.append(.line(x, y))
			case 0x56: // V
				guard let ny = scanner.number() else { return segments }
				y = oy + ny
				segments.append(.line(x, y))
			case 0x43, 0x53: // C, S
				var values: [Double] = []
				for _ in 0 ..< (upper == 0x43 ? 6 : 4) {
					scanner.skipSeparators()
					guard let value = scanner.number() else { return segments }
					values.append(value)
				}
				var x1 = x, y1 = y
				if upper == 0x43 {
					x1 = ox + values[0]; y1 = oy + values[1]
					values.removeFirst(2)
				} else if let control = lastControl {
					x1 = 2 * x - control.0; y1 = 2 * y - control.1
				}
				let x2 = ox + values[0], y2 = oy + values[1]
				let ex = ox + values[2], ey = oy + values[3]
				segments.append(.cubic(x1, y1, x2, y2, ex, ey))
				lastControl = (x2, y2)
				wasCubic = true
				x = ex; y = ey
			case 0x51, 0x54: // Q, T
				var values: [Double] = []
				for _ in 0 ..< (upper == 0x51 ? 4 : 2) {
					scanner.skipSeparators()
					guard let value = scanner.number() else { return segments }
					values.append(value)
				}
				var qx = x, qy = y
				if upper == 0x51 {
					qx = ox + values[0]; qy = oy + values[1]
					values.removeFirst(2)
				} else if let control = lastQuad {
					qx = 2 * x - control.0; qy = 2 * y - control.1
				}
				let ex = ox + values[0], ey = oy + values[1]
				segments.append(.cubic(x + 2 * (qx - x) / 3, y + 2 * (qy - y) / 3,
				                       ex + 2 * (qx - ex) / 3, ey + 2 * (qy - ey) / 3, ex, ey))
				lastQuad = (qx, qy)
				wasQuad = true
				x = ex; y = ey
			case 0x41: // A
				scanner.skipSeparators()
				guard let rx = scanner.number() else { return segments }
				scanner.skipSeparators()
				guard let ry = scanner.number() else { return segments }
				scanner.skipSeparators()
				guard let rotation = scanner.number() else { return segments }
				scanner.skipSeparators()
				guard let large = scanner.flag() else { return segments }
				scanner.skipSeparators()
				guard let sweep = scanner.flag() else { return segments }
				scanner.skipSeparators()
				guard let nx = scanner.number() else { return segments }
				scanner.skipSeparators()
				guard let ny = scanner.number() else { return segments }
				let ex = ox + nx, ey = oy + ny
				segments += arc(from: (x, y), radii: (rx, ry), rotation: rotation, large: large, sweep: sweep, to: (ex, ey))
				x = ex; y = ey
			default:
				return segments
			}
			if !wasCubic { lastControl = nil }
			if !wasQuad { lastQuad = nil }
			scanner.skipSeparators()
		}
		return segments
	}

	/// An SVG elliptical arc as cubic Béziers (SVG 1.1 implementation notes,
	/// endpoint → centre parameterisation).
	static func arc(from p0: (Double, Double), radii: (Double, Double), rotation: Double,
	                large: Bool, sweep: Bool, to p1: (Double, Double)) -> [SVGPathSegment] {
		if p0.0 == p1.0, p0.1 == p1.1 { return [] }
		var rx = abs(radii.0), ry = abs(radii.1)
		guard rx > 0, ry > 0 else { return [.line(p1.0, p1.1)] }
		let phi = rotation * .pi / 180
		let cosPhi = cos(phi), sinPhi = sin(phi)
		let dx = (p0.0 - p1.0) / 2, dy = (p0.1 - p1.1) / 2
		let x1 = cosPhi * dx + sinPhi * dy
		let y1 = -sinPhi * dx + cosPhi * dy
		let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
		if lambda > 1 {
			rx *= lambda.squareRoot()
			ry *= lambda.squareRoot()
		}
		let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
		let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
		var coefficient = denominator == 0 ? 0 : (max(0, numerator / denominator)).squareRoot()
		if large == sweep { coefficient = -coefficient }
		let cxp = coefficient * rx * y1 / ry
		let cyp = -coefficient * ry * x1 / rx
		let cx = cosPhi * cxp - sinPhi * cyp + (p0.0 + p1.0) / 2
		let cy = sinPhi * cxp + cosPhi * cyp + (p0.1 + p1.1) / 2
		let startAngle = atan2((y1 - cyp) / ry, (x1 - cxp) / rx)
		var delta = atan2((-y1 - cyp) / ry, (-x1 - cxp) / rx) - startAngle
		if sweep, delta < 0 { delta += 2 * .pi }
		if !sweep, delta > 0 { delta -= 2 * .pi }

		let pieces = max(1, Int((abs(delta) / (.pi / 2) - 1e-9).rounded(.up)))
		let step = delta / Double(pieces)
		let k = 4.0 / 3.0 * tan(step / 4)
		var result: [SVGPathSegment] = []
		var angle = startAngle
		func point(_ t: Double) -> (Double, Double) {
			(cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi, cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
		}
		func derivative(_ t: Double) -> (Double, Double) {
			(-rx * sin(t) * cosPhi - ry * cos(t) * sinPhi, -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
		}
		for piece in 0 ..< pieces {
			let next = angle + step
			let a = point(angle), b = point(next)
			let da = derivative(angle), db = derivative(next)
			let end = piece == pieces - 1 ? p1 : b
			result.append(.cubic(a.0 + k * da.0, a.1 + k * da.1, b.0 - k * db.0, b.1 - k * db.1, end.0, end.1))
			angle = next
		}
		return result
	}
}

// MARK: - Transforms, colours, lengths

enum SVGValues {

	/// Parse a `transform` list; `nil` on a syntax error (the attribute is then ignored).
	static func transform(_ text: String) -> SVGMatrix? {
		var scanner = SVGScanner(text)
		var result = SVGMatrix.identity
		scanner.skipSeparators()
		while !scanner.atEnd {
			let name = scanner.identifier()
			scanner.skipSpaces()
			guard scanner.peek == 0x28 else { return nil }
			scanner.index += 1
			var args: [Double] = []
			scanner.skipSeparators()
			while let value = scanner.number() {
				args.append(value)
				scanner.skipSeparators()
			}
			guard scanner.peek == 0x29 else { return nil }
			scanner.index += 1
			var matrix = SVGMatrix.identity
			switch (name, args.count) {
			case ("matrix", 6):
				matrix = SVGMatrix(a: args[0], b: args[1], c: args[2], d: args[3], e: args[4], f: args[5])
			case ("translate", 1): matrix.e = args[0]
			case ("translate", 2): matrix.e = args[0]; matrix.f = args[1]
			case ("scale", 1): matrix.a = args[0]; matrix.d = args[0]
			case ("scale", 2): matrix.a = args[0]; matrix.d = args[1]
			case ("rotate", 1), ("rotate", 3):
				let radians = args[0] * .pi / 180
				matrix = SVGMatrix(a: cos(radians), b: sin(radians), c: -sin(radians), d: cos(radians))
				if args.count == 3 {
					let shift = SVGMatrix(e: -args[1], f: -args[2])
					matrix = shift.then(matrix).then(SVGMatrix(e: args[1], f: args[2]))
				}
			case ("skewX", 1): matrix.c = tan(args[0] * .pi / 180)
			case ("skewY", 1): matrix.b = tan(args[0] * .pi / 180)
			default: return nil
			}
			// In a list the leftmost transform is the outermost, so it applies last.
			result = matrix.then(result)
			scanner.skipSeparators()
		}
		return result
	}

	/// A length in user units, or `nil` for a missing or percentage value.
	static func length(_ text: String?) -> Double? {
		guard let text else { return nil }
		var scanner = SVGScanner(text)
		guard let value = scanner.number() else { return nil }
		let unit = String(decoding: scanner.bytes[scanner.index...], as: UTF8.self).trimmingCharacters(in: .whitespaces)
		switch unit.lowercased() {
		case "", "px": return value
		case "pt": return value * 4 / 3
		case "pc": return value * 16
		case "mm": return value * 96 / 25.4
		case "cm": return value * 96 / 2.54
		case "in": return value * 96
		case "em": return value * 16
		case "ex": return value * 8
		default: return nil
		}
	}

	/// A paint: `.none` for `none`; `nil` for values this renderer cannot draw
	/// (gradients, patterns) or does not understand.
	enum Paint { case none, color(SVGColor) }

	static func paint(_ text: String, currentColor: SVGColor) -> Paint? {
		let value = text.trimmingCharacters(in: .whitespaces).lowercased()
		if value == "none" || value == "transparent" { return Paint.none }
		if value == "currentcolor" { return .color(currentColor) }
		return color(value).map(Paint.color)
	}

	static func color(_ value: String) -> SVGColor? {
		if value.hasPrefix("#") {
			let hex = Array(value.dropFirst())
			func nibble(_ i: Int) -> Double? { hex[i].hexDigitValue.map(Double.init) }
			func byte(_ i: Int) -> Double? {
				guard let high = hex[i].hexDigitValue, let low = hex[i + 1].hexDigitValue else { return nil }
				return Double(high * 16 + low) / 255
			}
			switch hex.count {
			case 3, 4:
				guard let r = nibble(0), let g = nibble(1), let b = nibble(2) else { return nil }
				return SVGColor(red: r / 15, green: g / 15, blue: b / 15)
			case 6, 8:
				guard let r = byte(0), let g = byte(2), let b = byte(4) else { return nil }
				return SVGColor(red: r, green: g, blue: b)
			default: return nil
			}
		}
		if value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), let close = value.firstIndex(of: ")") {
			let parts = value[value.index(after: open) ..< close]
				.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
			guard parts.count >= 3 else { return nil }
			var channels: [Double] = []
			for part in parts.prefix(3) {
				if part.hasSuffix("%") {
					guard let number = Double(part.dropLast()) else { return nil }
					channels.append(min(max(number / 100, 0), 1))
				} else {
					guard let number = Double(part) else { return nil }
					channels.append(min(max(number / 255, 0), 1))
				}
			}
			return SVGColor(red: channels[0], green: channels[1], blue: channels[2])
		}
		guard let rgb = namedColors[value] else { return nil }
		return SVGColor(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
	}

	static let namedColors: [String: Int] = [
		"black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "lime": 0x00FF00, "blue": 0x0000FF,
		"yellow": 0xFFFF00, "cyan": 0x00FFFF, "aqua": 0x00FFFF, "magenta": 0xFF00FF, "fuchsia": 0xFF00FF,
		"silver": 0xC0C0C0, "gray": 0x808080, "grey": 0x808080, "maroon": 0x800000, "olive": 0x808000,
		"green": 0x008000, "purple": 0x800080, "teal": 0x008080, "navy": 0x000080, "orange": 0xFFA500,
		"pink": 0xFFC0CB, "brown": 0xA52A2A, "gold": 0xFFD700, "indigo": 0x4B0082, "violet": 0xEE82EE,
		"crimson": 0xDC143C, "coral": 0xFF7F50, "salmon": 0xFA8072, "khaki": 0xF0E68C, "tan": 0xD2B48C,
		"beige": 0xF5F5DC, "ivory": 0xFFFFF0, "lavender": 0xE6E6FA, "turquoise": 0x40E0D0, "tomato": 0xFF6347,
		"orchid": 0xDA70D6, "plum": 0xDDA0DD, "sienna": 0xA0522D, "chocolate": 0xD2691E, "darkgray": 0xA9A9A9,
		"darkgrey": 0xA9A9A9, "lightgray": 0xD3D3D3, "lightgrey": 0xD3D3D3, "dimgray": 0x696969, "dimgrey": 0x696969,
		"darkblue": 0x00008B, "darkgreen": 0x006400, "darkred": 0x8B0000, "lightblue": 0xADD8E6,
		"lightgreen": 0x90EE90, "skyblue": 0x87CEEB, "steelblue": 0x4682B4, "royalblue": 0x4169E1,
		"slategray": 0x708090, "slategrey": 0x708090, "whitesmoke": 0xF5F5F5, "gainsboro": 0xDCDCDC,
		"forestgreen": 0x228B22, "seagreen": 0x2E8B57, "firebrick": 0xB22222, "hotpink": 0xFF69B4,
		"deeppink": 0xFF1493, "darkorange": 0xFF8C00, "limegreen": 0x32CD32, "midnightblue": 0x191970
	]
}

// MARK: - Building the tree

extension SVGTree {

	/// The properties that inherit down the tree.
	private struct Style {
		var fill = SVGValues.Paint.color(.black)
		var stroke = SVGValues.Paint.none
		var color = SVGColor.black
		var fillOpacity = 1.0
		var strokeOpacity = 1.0
		var evenOdd = false
		var strokeWidth = 1.0
		var cap = 0
		var join = 0
		var miterLimit = 4.0
		var dashes: [Double] = []
		var dashOffset = 0.0
	}

	/// Parse SVG file bytes; `nil` if they are not a usable SVG document.
	init?(data: Data) {
		guard let root = SVGXML.parse(data), root.name == "svg" else { return nil }

		var viewBox: (x: Double, y: Double, width: Double, height: Double)?
		let box = SVGScanner.numbers(root.attributes["viewBox"] ?? "")
		if box.count == 4, box[2] > 0, box[3] > 0 { viewBox = (box[0], box[1], box[2], box[3]) }

		var width = SVGValues.length(root.attributes["width"])
		var height = SVGValues.length(root.attributes["height"])
		if let width, width <= 0 { return nil }
		if let height, height <= 0 { return nil }
		if let viewBox {
			if width == nil, let height { width = height * viewBox.width / viewBox.height }
			if height == nil, let width { height = width * viewBox.height / viewBox.width }
			if width == nil { width = viewBox.width }
			if height == nil { height = viewBox.height }
		}
		let finalWidth = width ?? 300, finalHeight = height ?? 150
		self.width = finalWidth
		self.height = finalHeight
		self.viewBox = viewBox ?? (0, 0, finalWidth, finalHeight)

		let aspect = (root.attributes["preserveAspectRatio"] ?? "").split(separator: " ").map(String.init)
			.filter { $0 != "defer" }
		if let align = aspect.first {
			if align == "none" {
				alignX = .none; alignY = .none
			} else if align.count == 8 {
				let x = align.dropFirst(1).prefix(3), y = align.dropFirst(5)
				alignX = x == "Min" ? .min : x == "Max" ? .max : .mid
				alignY = y == "Min" ? .min : y == "Max" ? .max : .mid
			}
			slice = aspect.count > 1 && aspect[1] == "slice"
		}

		children = []
		var budget = 100_000
		let rootProperties = Self.properties(of: root)
		let rootStyle = Self.resolved(rootProperties, parent: Style())
		let inner = Self.nodes(in: root, parent: rootStyle, budget: &budget, depth: 0)
		let rootOpacity = Self.opacity(rootProperties)
		children = rootOpacity < 1 && !inner.isEmpty ? [.group(.identity, rootOpacity, inner)] : inner
	}

	private static func nodes(in element: SVGXMLElement, parent: Style, budget: inout Int, depth: Int) -> [SVGNode] {
		guard depth < SVGXML.maxDepth else { return [] }
		var result: [SVGNode] = []
		for child in element.children {
			budget -= 1
			guard budget > 0 else { break }
			let properties = Self.properties(of: child)
			if properties["display"] == "none" || properties["visibility"] == "hidden" { continue }

			let style = resolved(properties, parent: parent)
			let transform = properties["transform"].flatMap(SVGValues.transform) ?? .identity
			var alpha = opacity(properties)
			var node: SVGNode?
			switch child.name {
			case "g", "svg", "a", "switch":
				let inner = nodes(in: child, parent: style, budget: &budget, depth: depth + 1)
				if !inner.isEmpty { node = .group(.identity, 1, inner) }
			case "rect", "circle", "ellipse", "line", "polyline", "polygon", "path":
				let segments = shape(child.name, properties)
				if !segments.isEmpty, var drawn = path(segments, style) {
					// Opacity on a shape with a single paint folds into that paint;
					// with both, fill and stroke must composite together as a group.
					if alpha < 1, (drawn.fill == nil) != (drawn.stroke == nil) {
						drawn.fill?.opacity *= alpha
						drawn.stroke?.opacity *= alpha
						alpha = 1
					}
					node = .path(drawn)
				}
			default:
				break // text, gradients, filters, use, image, defs … are not drawn
			}
			guard let node else { continue }
			if transform == .identity, alpha >= 1 {
				result.append(node)
			} else {
				result.append(.group(transform, alpha, [node]))
			}
		}
		return result
	}

	private static func path(_ segments: [SVGPathSegment], _ style: Style) -> SVGPath? {
		var fill: SVGFill?
		var stroke: SVGStroke?
		if case .color(let color) = style.fill {
			fill = SVGFill(color: color, opacity: style.fillOpacity, evenOdd: style.evenOdd)
		}
		if case .color(let color) = style.stroke, style.strokeWidth > 0 {
			stroke = SVGStroke(color: color, opacity: style.strokeOpacity, width: style.strokeWidth,
			                   cap: style.cap, join: style.join, miterLimit: style.miterLimit,
			                   dashes: style.dashes, dashOffset: style.dashOffset)
		}
		guard fill != nil || stroke != nil else { return nil }
		return SVGPath(segments: segments, fill: fill, stroke: stroke)
	}

	/// The presentation attributes of an element, overridden by its `style`.
	private static func properties(of element: SVGXMLElement) -> [String: String] {
		var properties = element.attributes
		for declaration in (element.attributes["style"] ?? "").split(separator: ";") {
			guard let colon = declaration.firstIndex(of: ":") else { continue }
			properties[declaration[..<colon].trimmingCharacters(in: .whitespaces)] =
				declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespaces)
		}
		return properties
	}

	/// An element's own `opacity` (not inherited), clamped to 0…1.
	private static func opacity(_ properties: [String: String]) -> Double {
		guard let text = properties["opacity"] else { return 1 }
		let value = text.hasSuffix("%") ? Double(text.dropLast()).map { $0 / 100 } : Double(text)
		return value.map { min(max($0, 0), 1) } ?? 1
	}

	private static func resolved(_ properties: [String: String], parent: Style) -> Style {
		var style = parent
		if let value = properties["color"], let color = SVGValues.color(value.trimmingCharacters(in: .whitespaces).lowercased()) {
			style.color = color
		}
		if let value = properties["fill"], let paint = SVGValues.paint(value, currentColor: style.color) { style.fill = paint }
		if let value = properties["stroke"], let paint = SVGValues.paint(value, currentColor: style.color) { style.stroke = paint }
		func unit(_ key: String) -> Double? {
			guard let text = properties[key] else { return nil }
			let value = text.hasSuffix("%") ? Double(text.dropLast()).map { $0 / 100 } : Double(text)
			return value.map { min(max($0, 0), 1) }
		}
		if let value = unit("fill-opacity") { style.fillOpacity = value }
		if let value = unit("stroke-opacity") { style.strokeOpacity = value }
		if let value = properties["fill-rule"] { style.evenOdd = value == "evenodd" }
		if let value = SVGValues.length(properties["stroke-width"]) { style.strokeWidth = value }
		if let value = properties["stroke-linecap"] { style.cap = value == "round" ? 1 : value == "square" ? 2 : 0 }
		if let value = properties["stroke-linejoin"] { style.join = value == "round" ? 1 : value == "bevel" ? 2 : 0 }
		if let value = properties["stroke-miterlimit"], let limit = Double(value), limit >= 1 { style.miterLimit = limit }
		if let value = properties["stroke-dasharray"] {
			let dashes = SVGScanner.numbers(value)
			style.dashes = value == "none" || dashes.contains { $0 < 0 } || dashes.reduce(0, +) <= 0 ? [] : dashes
		}
		if let value = SVGValues.length(properties["stroke-dashoffset"]) { style.dashOffset = value }
		return style
	}

	/// The outline of a basic shape (or `d`) as path segments.
	private static func shape(_ name: String, _ p: [String: String]) -> [SVGPathSegment] {
		func number(_ key: String) -> Double { SVGValues.length(p[key]) ?? 0 }
		switch name {
		case "path":
			return SVGPathData.parse(p["d"] ?? "")
		case "line":
			return [.move(number("x1"), number("y1")), .line(number("x2"), number("y2"))]
		case "polyline", "polygon":
			let values = SVGScanner.numbers(p["points"] ?? "")
			guard values.count >= 4 else { return [] }
			var segments: [SVGPathSegment] = [.move(values[0], values[1])]
			for index in stride(from: 2, to: values.count - 1, by: 2) { segments.append(.line(values[index], values[index + 1])) }
			if name == "polygon" { segments.append(.close) }
			return segments
		case "rect":
			let x = number("x"), y = number("y")
			let width = number("width"), height = number("height")
			guard width > 0, height > 0 else { return [] }
			var rx = SVGValues.length(p["rx"]), ry = SVGValues.length(p["ry"])
			if rx == nil || rx! < 0 { rx = ry }
			if ry == nil || ry! < 0 { ry = rx }
			let radiusX = min(max(rx ?? 0, 0), width / 2), radiusY = min(max(ry ?? 0, 0), height / 2)
			guard radiusX > 0, radiusY > 0 else {
				return [.move(x, y), .line(x + width, y), .line(x + width, y + height), .line(x, y + height), .close]
			}
			var segments: [SVGPathSegment] = [.move(x + radiusX, y), .line(x + width - radiusX, y)]
			let corners = [(x + width, y + radiusY), (x + width - radiusX, y + height), (x, y + height - radiusY), (x + radiusX, y)]
			let edges = [(x + width, y + height - radiusY), (x + radiusX, y + height), (x, y + radiusY)]
			var from = (x + width - radiusX, y)
			for (index, corner) in corners.enumerated() {
				segments += SVGPathData.arc(from: from, radii: (radiusX, radiusY), rotation: 0, large: false, sweep: true, to: corner)
				from = corner
				if index < edges.count {
					segments.append(.line(edges[index].0, edges[index].1))
					from = edges[index]
				}
			}
			segments.append(.close)
			return segments
		case "circle", "ellipse":
			let cx = number("cx"), cy = number("cy")
			let rx = name == "circle" ? number("r") : number("rx")
			let ry = name == "circle" ? rx : number("ry")
			guard rx > 0, ry > 0 else { return [] }
			var segments: [SVGPathSegment] = [.move(cx + rx, cy)]
			segments += SVGPathData.arc(from: (cx + rx, cy), radii: (rx, ry), rotation: 0, large: false, sweep: true, to: (cx, cy + ry))
			segments += SVGPathData.arc(from: (cx, cy + ry), radii: (rx, ry), rotation: 0, large: false, sweep: true, to: (cx - rx, cy))
			segments += SVGPathData.arc(from: (cx - rx, cy), radii: (rx, ry), rotation: 0, large: false, sweep: true, to: (cx, cy - ry))
			segments += SVGPathData.arc(from: (cx, cy - ry), radii: (rx, ry), rotation: 0, large: false, sweep: true, to: (cx + rx, cy))
			segments.append(.close)
			return segments
		default:
			return []
		}
	}
}
