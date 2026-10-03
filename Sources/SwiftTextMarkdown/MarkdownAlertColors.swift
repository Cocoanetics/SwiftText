import Foundation

/// The colours of alert boxes for the writers that don't read CSS (Pages, DOCX): the
/// built-in palettes (``MarkdownAlertPalette``), overridden by a stylesheet's
/// `.markdown-alert` and `.markdown-alert-KIND` rules as a browser applies them after
/// the built-in styles. One stylesheet therefore recolours the boxes in every format.
///
/// It reads the fill from `background` or `background-color`, the accent border from
/// `border-left-color`, `border-left`, `border-color` or `border`, and the text from
/// `color`. Colours can be `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()` or `rgba()`. A
/// translucent colour is mixed with white, the page, because Pages and Word fill boxes
/// with opaque colours. A declaration wins as in CSS: `!important` first, then
/// specificity, then order in the stylesheet. Only selectors that match the box the HTML
/// writer generates count: `<aside class="markdown-alert markdown-alert-KIND">`, so
/// `.markdown-alert`, `.markdown-alert-note`, `aside.markdown-alert.markdown-alert-note`,
/// but not `section.markdown-alert-note` or `.special.markdown-alert-note`. Rules in
/// `@media` and other at-rules are ignored, and so are selectors with combinators,
/// attributes or pseudo-classes.
public struct MarkdownAlertColors: Sendable, Equatable {
	/// The built-in colours: the same as the default stylesheets.
	public static let builtIn = MarkdownAlertColors()

	private enum Property: Hashable, Sendable {
		case background, border, text
	}

	/// A declared colour and what decides between competing declarations.
	private struct Declaration: Equatable, Sendable {
		var important: Bool
		var specificity: Int
		var order: Int
		var hex: String

		func wins(over other: Declaration) -> Bool {
			(important ? 1 : 0, specificity, order) > (other.important ? 1 : 0, other.specificity, other.order)
		}
	}

	/// Declarations of `.markdown-alert` rules, which colour every kind.
	private var base: [Property: Declaration] = [:]
	/// Declarations of `.markdown-alert-KIND` rules, by kind.
	private var kinds: [String: [Property: Declaration]] = [:]

	public init() {}

	/// The colours a stylesheet sets for alert boxes, over the built-in ones.
	public init(css: String) {
		var order = 0
		for rule in Self.styleRules(in: css) {
			for selector in rule.selectors {
				guard let target = Self.alertTarget(of: selector) else { continue }
				for (property, hex, important) in Self.colors(in: rule.declarations) {
					order += 1
					let declaration = Declaration(important: important, specificity: target.specificity, order: order, hex: hex)
					if let kind = target.kind {
						if let current = kinds[kind]?[property], !declaration.wins(over: current) { continue }
						kinds[kind, default: [:]][property] = declaration
					} else {
						if let current = base[property], !declaration.wins(over: current) { continue }
						base[property] = declaration
					}
				}
			}
		}
	}

	/// Whether the stylesheet set no alert colours.
	public var isEmpty: Bool { base.isEmpty && kinds.isEmpty }

	/// The colours of a box of `kind`.
	public func palette(forKind kind: String) -> MarkdownAlertPalette {
		var palette = MarkdownAlertPalette.palette(forKind: kind)
		let own = kinds[kind] ?? [:]
		func winner(_ property: Property) -> String? {
			switch (base[property], own[property]) {
			case let (shared?, specific?): return shared.wins(over: specific) ? shared.hex : specific.hex
			case let (shared?, nil): return shared.hex
			case let (nil, specific?): return specific.hex
			case (nil, nil): return nil
			}
		}
		if let hex = winner(.background) { palette.background = hex }
		if let hex = winner(.border) { palette.border = hex }
		if let hex = winner(.text) { palette.text = hex }
		return palette
	}

	// MARK: - Reading the stylesheet

	private struct StyleRule {
		var selectors: [String]
		var declarations: String
	}

	/// The top-level style rules, in order; comments and at-rules (with their blocks)
	/// are skipped.
	private static func styleRules(in css: String) -> [StyleRule] {
		let text = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: " ", options: .regularExpression)
		var rules = [StyleRule]()
		var prelude = ""
		var block = ""
		var depth = 0
		for character in text {
			switch character {
			case "{":
				if depth > 0 { block.append(character) }
				depth += 1
			case "}":
				depth -= 1
				if depth > 0 {
					block.append(character)
				} else {
					depth = 0
					let selectors = prelude.trimmingCharacters(in: .whitespacesAndNewlines)
					if !selectors.hasPrefix("@") {
						rules.append(StyleRule(selectors: selectors.split(separator: ",").map(String.init), declarations: block))
					}
					prelude = ""
					block = ""
				}
			case ";" where depth == 0:
				prelude = ""                                  // e.g. `@import …;`
			default:
				if depth == 0 { prelude.append(character) } else { block.append(character) }
			}
		}
		return rules
	}

	/// The alert kind a simple selector (`.markdown-alert-note`, `aside.markdown-alert`)
	/// targets — `nil` for the base rule — and its specificity, or `nil` when the selector
	/// can't match the generated `<aside class="markdown-alert markdown-alert-KIND">`: another
	/// tag, a class the box lacks (the title's included), or two kinds.
	private static func alertTarget(of selector: String) -> (kind: String?, specificity: Int)? {
		let selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
		guard selector.range(of: #"^[A-Za-z][A-Za-z0-9-]*?(\.[A-Za-z0-9_-]+)+$|^(\.[A-Za-z0-9_-]+)+$"#, options: .regularExpression) != nil
		else { return nil }
		let parts = selector.split(separator: ".", omittingEmptySubsequences: false)
		let tag = String(parts.first ?? "")
		guard tag.isEmpty || tag.lowercased() == "aside" else { return nil }      // tag names ignore case
		let classes = parts.dropFirst().map(String.init)                          // class names don't
		guard classes.allSatisfy({ $0 == "markdown-alert" || $0.hasPrefix("markdown-alert-") }),
			  !classes.contains("markdown-alert-title") else { return nil }
		let kinds = Set(classes.filter { $0.hasPrefix("markdown-alert-") }.map { String($0.dropFirst("markdown-alert-".count)) })
		guard kinds.count <= 1 else { return nil }
		return (kinds.first, classes.count * 10 + (tag.isEmpty ? 0 : 1))
	}

	/// The alert colours declared in a rule's block, in order, with whether each is `!important`.
	private static func colors(in declarations: String) -> [(Property, String, Bool)] {
		var result = [(Property, String, Bool)]()
		for declaration in declarations.split(separator: ";") {
			guard let colon = declaration.firstIndex(of: ":") else { continue }
			let name = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			var value = String(declaration[declaration.index(after: colon)...])
			let importance = value.range(of: #"!\s*important\s*$"#, options: [.regularExpression, .caseInsensitive])
			if let importance { value.removeSubrange(importance) }
			value = value.trimmingCharacters(in: .whitespacesAndNewlines)
			let property: Property
			switch name {
			case "background", "background-color": property = .background
			case "border-left-color", "border-left", "border-color", "border": property = .border
			case "color": property = .text
			default: continue
			}
			if let hex = hexColor(in: value) { result.append((property, hex, importance != nil)) }
		}
		return result
	}

	/// The first colour in a value as `RRGGBB`, a translucent one mixed with white.
	static func hexColor(in value: String) -> String? {
		if let match = value.range(of: #"#([0-9A-Fa-f]{8}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{3,4})\b"#, options: .regularExpression) {
			var digits = String(value[match].dropFirst())
			if digits.count <= 4 { digits = digits.map { "\($0)\($0)" }.joined() }
			guard let raw = UInt64(digits, radix: 16) else { return nil }
			if digits.count == 8 {
				return hex(red: Double(raw >> 24 & 0xFF), green: Double(raw >> 16 & 0xFF), blue: Double(raw >> 8 & 0xFF),
				           alpha: Double(raw & 0xFF) / 255)
			}
			return hex(red: Double(raw >> 16 & 0xFF), green: Double(raw >> 8 & 0xFF), blue: Double(raw & 0xFF), alpha: 1)
		}
		guard let match = value.range(of: #"rgba?\([^)]*\)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
		let inner = value[match].drop { $0 != "(" }.dropFirst().dropLast()
		let numbers = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
		guard numbers.count >= 3 else { return nil }
		func channel(_ token: String) -> Double? {
			token.hasSuffix("%") ? Double(token.dropLast()).map { $0 * 255 / 100 } : Double(token)
		}
		func alpha(_ token: String) -> Double? {
			token.hasSuffix("%") ? Double(token.dropLast()).map { $0 / 100 } : Double(token)
		}
		guard let red = channel(numbers[0]), let green = channel(numbers[1]), let blue = channel(numbers[2]) else { return nil }
		return hex(red: red, green: green, blue: blue, alpha: numbers.count > 3 ? alpha(numbers[3]) ?? 1 : 1)
	}

	private static func hex(red: Double, green: Double, blue: Double, alpha: Double) -> String {
		let alpha = min(max(alpha, 0), 1)
		func mixed(_ channel: Double) -> Int {
			Int((255 - alpha * (255 - min(max(channel, 0), 255))).rounded())
		}
		return String(format: "%02X%02X%02X", mixed(red), mixed(green), mixed(blue))
	}
}
