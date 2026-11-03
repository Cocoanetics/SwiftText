//  PresentationalHints.swift
//  SwiftTextCSS
//
//  HTML presentational hints: the attributes HTML still maps onto CSS —
//  `width` and `height`, `bgcolor`, `align` and `valign`, `cellpadding` and
//  `cellspacing`, a table's `border`, `<font>` — following the rendering
//  section of the HTML standard. HTML email depends on them: Outlook ignores
//  much of CSS, so an email's table geometry is commonly spelled out in
//  attributes alone. They cascade as author declarations of zero specificity
//  ahead of every style sheet, so any CSS rule for the same property wins.

import Foundation

/// The CSS declarations an element's presentational attributes stand for.
func presentationalHints(for element: SelectorElement) -> [Declaration] {
	var hints = PresentationalHints(element: element)
	hints.collect()
	guard !hints.css.isEmpty else { return [] }
	return parseDeclarations(inlineStyle: hints.css.joined(separator: "; "))
}

/// HTML's own adjustment of a computed style: a table resets the legacy
/// `-webkit-*` alignments it would inherit from `<center>` or an `align`
/// attribute, so they centre the table without centring the text in it.
func adjustStyle(_ style: inout ComputedStyle, for element: SelectorElement) {
	if element.localName == "table", style.textAlign.isLegacy {
		style.textAlign = .start
	}
}

private struct PresentationalHints {
	let element: SelectorElement
	/// Declarations built only from values parsed and re-formatted here, so an
	/// attribute cannot smuggle in CSS of its own.
	var css: [String] = []

	init(element: SelectorElement) {
		self.element = element
	}

	mutating func collect() {
		switch element.localName {
		case "body": body()
		case "table": table()
		case "thead", "tbody", "tfoot", "tr": rowOrGroup()
		case "td", "th": cell()
		case "img": image()
		case "div": textAlign(legacy: true)
		case "p", "h1", "h2", "h3", "h4", "h5", "h6": textAlign(legacy: false)
		case "font": font()
		default: break
		}
	}

	private func attribute(_ name: String) -> String? {
		element.attributeValue(name)?.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	// MARK: - Elements

	private mutating func body() {
		background()
		if let color = Self.color(attribute("text")) { css.append("color: \(color)") }
		let margins = [
			("top", attribute("topmargin") ?? attribute("marginheight")),
			("bottom", attribute("bottommargin") ?? attribute("marginheight")),
			("left", attribute("leftmargin") ?? attribute("marginwidth")),
			("right", attribute("rightmargin") ?? attribute("marginwidth"))
		]
		for (edge, value) in margins {
			if let pixels = Self.nonNegativeInteger(value) { css.append("margin-\(edge): \(pixels)px") }
		}
	}

	private mutating func table() {
		if let width = Self.dimension(attribute("width"), allowsZero: false) { css.append("width: \(width)") }
		if let height = Self.dimension(attribute("height"), allowsZero: true) { css.append("height: \(height)") }
		background()
		if let spacing = Self.nonNegativeInteger(attribute("cellspacing")) { css.append("border-spacing: \(spacing)px") }
		if let border = Self.tableBorder(of: element), border > 0 {
			css.append("border: \(border)px outset \(Self.color(attribute("bordercolor")) ?? "gray")")
		}
		// `left` and `right` float the table, which is not modelled.
		if attribute("align")?.lowercased() == "center" {
			css.append("margin-left: auto")
			css.append("margin-right: auto")
		}
	}

	private mutating func rowOrGroup() {
		background()
		textAlign(legacy: true)
		verticalAlign()
		if element.localName == "tr", let height = Self.dimension(attribute("height"), allowsZero: false) {
			css.append("height: \(height)")
		}
	}

	private mutating func cell() {
		if let width = Self.dimension(attribute("width"), allowsZero: false) { css.append("width: \(width)") }
		if let height = Self.dimension(attribute("height"), allowsZero: false) { css.append("height: \(height)") }
		background()
		textAlign(legacy: true)
		verticalAlign()
		if attribute("nowrap") != nil { css.append("white-space: nowrap") }
		if let table = owningTable {
			if let padding = Self.nonNegativeInteger(table.attributeValue("cellpadding")) {
				css.append("padding: \(padding)px")
			}
			if let border = Self.tableBorder(of: table), border > 0 {
				css.append("border: 1px inset \(Self.color(table.attributeValue("bordercolor")) ?? "gray")")
			}
		}
	}

	private mutating func image() {
		if let width = Self.dimension(attribute("width"), allowsZero: true) { css.append("width: \(width)") }
		if let height = Self.dimension(attribute("height"), allowsZero: true) { css.append("height: \(height)") }
		if let space = Self.nonNegativeInteger(attribute("hspace")) {
			css.append("margin-left: \(space)px")
			css.append("margin-right: \(space)px")
		}
		if let space = Self.nonNegativeInteger(attribute("vspace")) {
			css.append("margin-top: \(space)px")
			css.append("margin-bottom: \(space)px")
		}
		if let border = Self.nonNegativeInteger(attribute("border")) { css.append("border: \(border)px solid") }
		// `left` and `right` float the image, which is not modelled.
		switch attribute("align")?.lowercased() {
		case "middle", "absmiddle", "abscenter": css.append("vertical-align: middle")
		case "top": css.append("vertical-align: top")
		case "texttop": css.append("vertical-align: text-top")
		case "bottom", "absbottom": css.append("vertical-align: bottom")
		case "baseline": css.append("vertical-align: baseline")
		default: break
		}
	}

	private mutating func font() {
		if let color = Self.color(attribute("color")) { css.append("color: \(color)") }
		if let face = attribute("face"), !face.isEmpty,
		   face.allSatisfy({ $0.isLetter || $0.isNumber || " ,-_'\"".contains($0) }) {
			css.append("font-family: \(face)")
		}
		if let size = Self.legacyFontSize(attribute("size")) { css.append("font-size: \(size)px") }
	}

	// MARK: - Shared attributes

	private mutating func background() {
		if let color = Self.color(attribute("bgcolor")) { css.append("background-color: \(color)") }
	}

	/// `align`: on `div`, rows and cells the legacy `-webkit-*` alignments,
	/// which also align block children — what a `<td align="center">` around a
	/// nested table relies on to centre it.
	private mutating func textAlign(legacy: Bool) {
		let value: String
		switch attribute("align")?.lowercased() {
		case "left": value = legacy ? "-webkit-left" : "left"
		case "right": value = legacy ? "-webkit-right" : "right"
		case "center", "middle": value = legacy ? "-webkit-center" : "center"
		case "justify": value = "justify"
		default: return
		}
		css.append("text-align: \(value)")
	}

	private mutating func verticalAlign() {
		switch attribute("valign")?.lowercased() {
		case "top": css.append("vertical-align: top")
		case "middle", "center": css.append("vertical-align: middle")
		case "bottom": css.append("vertical-align: bottom")
		case "baseline": css.append("vertical-align: baseline")
		default: break
		}
	}

	/// The table a cell belongs to: its nearest `table` ancestor.
	private var owningTable: SelectorElement? {
		var ancestor = element.parentSelectorElement
		while let current = ancestor, current.localName != "table" {
			ancestor = current.parentSelectorElement
		}
		return ancestor
	}

	// MARK: - Attribute value parsing (HTML §2.3.4)

	/// A table's `border` width: its value, or 1 when the attribute is present
	/// but not a number.
	private static func tableBorder(of table: SelectorElement) -> Int? {
		guard let value = table.attributeValue("border") else { return nil }
		return nonNegativeInteger(value) ?? 1
	}

	/// The rules for parsing non-negative integers: leading digits, ignoring
	/// whatever follows.
	static func nonNegativeInteger(_ value: String?) -> Int? {
		guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
		if text.hasPrefix("+") { text.removeFirst() }
		let digits = text.prefix { $0.isASCII && $0.isNumber }
		guard !digits.isEmpty else { return nil }
		return Int(digits.prefix(9))
	}

	/// The rules for parsing dimension values: a number of pixels, or of percent
	/// when a `%` follows; anything else after the number is ignored, so
	/// `600px` reads as 600.
	static func dimension(_ value: String?, allowsZero: Bool) -> String? {
		guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
		let integer = text.prefix { $0.isASCII && $0.isNumber }
		guard !integer.isEmpty else { return nil }
		var rest = text.dropFirst(integer.count)
		var fraction = Substring("")
		if rest.first == "." {
			fraction = rest.dropFirst().prefix { $0.isASCII && $0.isNumber }
			rest = rest.dropFirst(1 + fraction.count)
		}
		guard let number = Double(fraction.isEmpty ? String(integer) : "\(integer).\(fraction)"),
		      number.isFinite, allowsZero || number > 0 else { return nil }
		let clamped = min(number, 100_000)
		let formatted = clamped == clamped.rounded() ? String(Int(clamped)) : String(clamped)
		return rest.first == "%" ? "\(formatted)%" : "\(formatted)px"
	}

	/// A legacy colour value, as far as email uses them: a CSS colour name, or
	/// three or six hex digits with or without `#`.
	static func color(_ value: String?) -> String? {
		guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
		      text.lowercased() != "transparent" else { return nil }
		let digits = text.hasPrefix("#") ? text.dropFirst() : Substring(text)
		if digits.count == 3 || digits.count == 6, digits.allSatisfy(\.isHexDigit) { return "#\(digits)" }
		if text.allSatisfy({ $0.isASCII && $0.isLetter }) { return text }
		return nil
	}

	/// `<font size>`: 1–7, or relative to 3 with a sign, in pixels.
	static func legacyFontSize(_ value: String?) -> Int? {
		guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
		var sign = 0
		if text.hasPrefix("+") { sign = 1; text.removeFirst() } else if text.hasPrefix("-") { sign = -1; text.removeFirst() }
		guard let number = nonNegativeInteger(text) else { return nil }
		let size = min(7, max(1, sign == 0 ? number : 3 + sign * number))
		return [10, 13, 16, 18, 24, 32, 48][size - 1]
	}
}
