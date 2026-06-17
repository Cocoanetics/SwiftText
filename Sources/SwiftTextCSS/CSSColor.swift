//  CSSColor.swift
//  SwiftTextCSS
//
//  CSS Color Level 3 parsing: a Swift port of tinycss2's `color3.py`. Resolves
//  keywords, #hex, rgb()/rgba() and hsl()/hsla() to RGBA in the 0…1 range.

import Foundation

/// An RGBA color with channels in the 0…1 range.
///
/// Alpha is clamped to 0…1, but red/green/blue may fall outside it (e.g.
/// `rgb(-10%, 120%, 0%)` yields `(-0.1, 1.2, 0, 1)`), matching CSS Color 3.
public struct RGBA: Equatable, Sendable {
	public var red: Double
	public var green: Double
	public var blue: Double
	public var alpha: Double

	public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) {
		self.red = red
		self.green = green
		self.blue = blue
		self.alpha = alpha
	}
}

/// The result of parsing a color: either an explicit color or the
/// `currentColor` keyword, which resolves to the element's `color` later.
public enum CSSColor: Equatable, Sendable {
	case currentColor
	case rgba(RGBA)
}

/// Parse a color from a CSS string, or `nil` if it is not a valid color.
public func parseColor(_ input: String) -> CSSColor? {
	let significant = tokenizeComponentValues(input, skipComments: true).filter { !$0.isWhitespaceOrComment }
	guard significant.count == 1 else { return nil }
	return parseColor(significant[0])
}

/// Parse a color from a single component value.
public func parseColor(_ value: ComponentValue) -> CSSColor? {
	switch value.token {
	case .ident(let name):
		return colorKeywords[name.asciiLowercased]
	case .hash(let hex, _):
		return parseHashColor(hex)
	case .function(let name, let arguments):
		guard let args = commaSeparated(arguments) else { return nil }
		switch name.asciiLowercased {
		case "rgb":
			return parseRGB(args, alpha: 1)
		case "rgba":
			guard args.count >= 4, let alpha = parseAlpha(args[3]) else { return nil }
			return parseRGB(Array(args.prefix(3)), alpha: alpha)
		case "hsl":
			return parseHSL(args, alpha: 1)
		case "hsla":
			guard args.count >= 4, let alpha = parseAlpha(args[3]) else { return nil }
			return parseHSL(Array(args.prefix(3)), alpha: alpha)
		default:
			return nil
		}
	default:
		return nil
	}
}

// MARK: - Helpers

private func parseHashColor(_ hex: String) -> CSSColor? {
	let scalars = Array(hex.unicodeScalars)
	guard scalars.allSatisfy({ isHexDigit($0) }) else { return nil }

	func channel(_ string: String) -> Double? {
		guard let value = Int(string, radix: 16) else { return nil }
		return Double(value) / 255
	}

	switch scalars.count {
	case 3, 4:
		// Each digit is doubled: #rgb(a).
		let doubled = hex.map { String(repeating: $0, count: 2) }
		guard let r = channel(doubled[0]), let g = channel(doubled[1]), let b = channel(doubled[2]) else { return nil }
		let a = scalars.count == 4 ? channel(doubled[3]) ?? 1 : 1
		return .rgba(RGBA(r, g, b, a))
	case 6, 8:
		let pairs = stride(from: 0, to: scalars.count, by: 2).map { String(String.UnicodeScalarView(scalars[$0 ..< $0 + 2])) }
		guard let r = channel(pairs[0]), let g = channel(pairs[1]), let b = channel(pairs[2]) else { return nil }
		let a = scalars.count == 8 ? channel(pairs[3]) ?? 1 : 1
		return .rgba(RGBA(r, g, b, a))
	default:
		return nil
	}
}

/// Split function arguments into single tokens separated by mandatory commas.
private func commaSeparated(_ tokens: [ComponentValue]) -> [ComponentValue]? {
	let significant = tokens.filter { !$0.isWhitespaceOrComment }
	if significant.isEmpty { return [] }
	guard significant.count % 2 == 1 else { return nil }
	for index in stride(from: 1, to: significant.count, by: 2) where !significant[index].isLiteral(",") {
		return nil
	}
	return stride(from: 0, to: significant.count, by: 2).map { significant[$0] }
}

private func parseAlpha(_ value: ComponentValue) -> Double? {
	if case .number(let number, _, _) = value.token {
		return min(1, max(0, number))
	}
	return nil
}

private func parseRGB(_ args: [ComponentValue], alpha: Double) -> CSSColor? {
	guard args.count == 3 else { return nil }
	// Three integers (0…255) …
	if let channels = integerChannels(args) {
		return .rgba(RGBA(channels[0] / 255, channels[1] / 255, channels[2] / 255, alpha))
	}
	// … or three percentages (0…100%).
	if let channels = percentageChannels(args) {
		return .rgba(RGBA(channels[0] / 100, channels[1] / 100, channels[2] / 100, alpha))
	}
	return nil
}

private func parseHSL(_ args: [ComponentValue], alpha: Double) -> CSSColor? {
	guard args.count == 3 else { return nil }
	guard case .number(let hue, _, _) = args[0].token,
	      case .percentage(let saturation, _, _) = args[1].token,
	      case .percentage(let lightness, _, _) = args[2].token else { return nil }
	let (r, g, b) = hslToRGB(hue: hue / 360, saturation: saturation / 100, lightness: lightness / 100)
	return .rgba(RGBA(r, g, b, alpha))
}

private func integerChannels(_ args: [ComponentValue]) -> [Double]? {
	var result: [Double] = []
	for arg in args {
		guard case .number(_, let int, _) = arg.token, let intValue = int else { return nil }
		result.append(Double(intValue))
	}
	return result
}

private func percentageChannels(_ args: [ComponentValue]) -> [Double]? {
	var result: [Double] = []
	for arg in args {
		guard case .percentage(let value, _, _) = arg.token else { return nil }
		result.append(value)
	}
	return result
}

private func hslToRGB(hue: Double, saturation: Double, lightness: Double) -> (Double, Double, Double) {
	if saturation == 0 {
		return (lightness, lightness, lightness)
	}
	let m2 = lightness <= 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
	let m1 = 2 * lightness - m2

	func value(_ hueValue: Double) -> Double {
		var h = hueValue.truncatingRemainder(dividingBy: 1)
		if h < 0 { h += 1 }
		if h < 1.0 / 6 { return m1 + (m2 - m1) * h * 6 }
		if h < 0.5 { return m2 }
		if h < 2.0 / 3 { return m1 + (m2 - m1) * (2.0 / 3 - h) * 6 }
		return m1
	}

	return (value(hue + 1.0 / 3), value(hue), value(hue - 1.0 / 3))
}

private func isHexDigit(_ s: Unicode.Scalar) -> Bool {
	(s >= "0" && s <= "9") || (s >= "a" && s <= "f") || (s >= "A" && s <= "F")
}

// MARK: - Keyword table

private func rgb255(_ r: Int, _ g: Int, _ b: Int) -> CSSColor {
	.rgba(RGBA(Double(r) / 255, Double(g) / 255, Double(b) / 255, 1))
}

/// The CSS Color 3 keyword table (extended set), plus `transparent` and
/// `currentColor`.
let colorKeywords: [String: CSSColor] = [
	"transparent": .rgba(RGBA(0, 0, 0, 0)),
	"currentcolor": .currentColor,
	"aliceblue": rgb255(240, 248, 255), "antiquewhite": rgb255(250, 235, 215),
	"aqua": rgb255(0, 255, 255), "aquamarine": rgb255(127, 255, 212),
	"azure": rgb255(240, 255, 255), "beige": rgb255(245, 245, 220),
	"bisque": rgb255(255, 228, 196), "black": rgb255(0, 0, 0),
	"blanchedalmond": rgb255(255, 235, 205), "blue": rgb255(0, 0, 255),
	"blueviolet": rgb255(138, 43, 226), "brown": rgb255(165, 42, 42),
	"burlywood": rgb255(222, 184, 135), "cadetblue": rgb255(95, 158, 160),
	"chartreuse": rgb255(127, 255, 0), "chocolate": rgb255(210, 105, 30),
	"coral": rgb255(255, 127, 80), "cornflowerblue": rgb255(100, 149, 237),
	"cornsilk": rgb255(255, 248, 220), "crimson": rgb255(220, 20, 60),
	"cyan": rgb255(0, 255, 255), "darkblue": rgb255(0, 0, 139),
	"darkcyan": rgb255(0, 139, 139), "darkgoldenrod": rgb255(184, 134, 11),
	"darkgray": rgb255(169, 169, 169), "darkgreen": rgb255(0, 100, 0),
	"darkgrey": rgb255(169, 169, 169), "darkkhaki": rgb255(189, 183, 107),
	"darkmagenta": rgb255(139, 0, 139), "darkolivegreen": rgb255(85, 107, 47),
	"darkorange": rgb255(255, 140, 0), "darkorchid": rgb255(153, 50, 204),
	"darkred": rgb255(139, 0, 0), "darksalmon": rgb255(233, 150, 122),
	"darkseagreen": rgb255(143, 188, 143), "darkslateblue": rgb255(72, 61, 139),
	"darkslategray": rgb255(47, 79, 79), "darkslategrey": rgb255(47, 79, 79),
	"darkturquoise": rgb255(0, 206, 209), "darkviolet": rgb255(148, 0, 211),
	"deeppink": rgb255(255, 20, 147), "deepskyblue": rgb255(0, 191, 255),
	"dimgray": rgb255(105, 105, 105), "dimgrey": rgb255(105, 105, 105),
	"dodgerblue": rgb255(30, 144, 255), "firebrick": rgb255(178, 34, 34),
	"floralwhite": rgb255(255, 250, 240), "forestgreen": rgb255(34, 139, 34),
	"fuchsia": rgb255(255, 0, 255), "gainsboro": rgb255(220, 220, 220),
	"ghostwhite": rgb255(248, 248, 255), "gold": rgb255(255, 215, 0),
	"goldenrod": rgb255(218, 165, 32), "gray": rgb255(128, 128, 128),
	"green": rgb255(0, 128, 0), "greenyellow": rgb255(173, 255, 47),
	"grey": rgb255(128, 128, 128), "honeydew": rgb255(240, 255, 240),
	"hotpink": rgb255(255, 105, 180), "indianred": rgb255(205, 92, 92),
	"indigo": rgb255(75, 0, 130), "ivory": rgb255(255, 255, 240),
	"khaki": rgb255(240, 230, 140), "lavender": rgb255(230, 230, 250),
	"lavenderblush": rgb255(255, 240, 245), "lawngreen": rgb255(124, 252, 0),
	"lemonchiffon": rgb255(255, 250, 205), "lightblue": rgb255(173, 216, 230),
	"lightcoral": rgb255(240, 128, 128), "lightcyan": rgb255(224, 255, 255),
	"lightgoldenrodyellow": rgb255(250, 250, 210), "lightgray": rgb255(211, 211, 211),
	"lightgreen": rgb255(144, 238, 144), "lightgrey": rgb255(211, 211, 211),
	"lightpink": rgb255(255, 182, 193), "lightsalmon": rgb255(255, 160, 122),
	"lightseagreen": rgb255(32, 178, 170), "lightskyblue": rgb255(135, 206, 250),
	"lightslategray": rgb255(119, 136, 153), "lightslategrey": rgb255(119, 136, 153),
	"lightsteelblue": rgb255(176, 196, 222), "lightyellow": rgb255(255, 255, 224),
	"lime": rgb255(0, 255, 0), "limegreen": rgb255(50, 205, 50),
	"linen": rgb255(250, 240, 230), "magenta": rgb255(255, 0, 255),
	"maroon": rgb255(128, 0, 0), "mediumaquamarine": rgb255(102, 205, 170),
	"mediumblue": rgb255(0, 0, 205), "mediumorchid": rgb255(186, 85, 211),
	"mediumpurple": rgb255(147, 112, 219), "mediumseagreen": rgb255(60, 179, 113),
	"mediumslateblue": rgb255(123, 104, 238), "mediumspringgreen": rgb255(0, 250, 154),
	"mediumturquoise": rgb255(72, 209, 204), "mediumvioletred": rgb255(199, 21, 133),
	"midnightblue": rgb255(25, 25, 112), "mintcream": rgb255(245, 255, 250),
	"mistyrose": rgb255(255, 228, 225), "moccasin": rgb255(255, 228, 181),
	"navajowhite": rgb255(255, 222, 173), "navy": rgb255(0, 0, 128),
	"oldlace": rgb255(253, 245, 230), "olive": rgb255(128, 128, 0),
	"olivedrab": rgb255(107, 142, 35), "orange": rgb255(255, 165, 0),
	"orangered": rgb255(255, 69, 0), "orchid": rgb255(218, 112, 214),
	"palegoldenrod": rgb255(238, 232, 170), "palegreen": rgb255(152, 251, 152),
	"paleturquoise": rgb255(175, 238, 238), "palevioletred": rgb255(219, 112, 147),
	"papayawhip": rgb255(255, 239, 213), "peachpuff": rgb255(255, 218, 185),
	"peru": rgb255(205, 133, 63), "pink": rgb255(255, 192, 203),
	"plum": rgb255(221, 160, 221), "powderblue": rgb255(176, 224, 230),
	"purple": rgb255(128, 0, 128), "red": rgb255(255, 0, 0),
	"rosybrown": rgb255(188, 143, 143), "royalblue": rgb255(65, 105, 225),
	"saddlebrown": rgb255(139, 69, 19), "salmon": rgb255(250, 128, 114),
	"sandybrown": rgb255(244, 164, 96), "seagreen": rgb255(46, 139, 87),
	"seashell": rgb255(255, 245, 238), "sienna": rgb255(160, 82, 45),
	"silver": rgb255(192, 192, 192), "skyblue": rgb255(135, 206, 235),
	"slateblue": rgb255(106, 90, 205), "slategray": rgb255(112, 128, 144),
	"slategrey": rgb255(112, 128, 144), "snow": rgb255(255, 250, 250),
	"springgreen": rgb255(0, 255, 127), "steelblue": rgb255(70, 130, 180),
	"tan": rgb255(210, 180, 140), "teal": rgb255(0, 128, 128),
	"thistle": rgb255(216, 191, 216), "tomato": rgb255(255, 99, 71),
	"turquoise": rgb255(64, 224, 208), "violet": rgb255(238, 130, 238),
	"wheat": rgb255(245, 222, 179), "white": rgb255(255, 255, 255),
	"whitesmoke": rgb255(245, 245, 245), "yellow": rgb255(255, 255, 0),
	"yellowgreen": rgb255(154, 205, 50),
]
