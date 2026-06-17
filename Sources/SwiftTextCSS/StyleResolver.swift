//  StyleResolver.swift
//  SwiftTextCSS
//
//  The cascade: collect matching declarations from the user-agent and author
//  origins plus inline styles, resolve them by origin/importance/specificity/
//  order, and compute a typed `ComputedStyle`. Shorthands are expanded to
//  longhands before cascading, matching the CSS model.

import Foundation

/// A cascade origin (the user origin is not modeled).
public enum Origin: Sendable {
	case userAgent
	case author
}

/// A single selector paired with the declarations to apply when it matches.
struct CompiledRule {
	let selector: ComplexSelector
	let declarations: [Declaration]
	let origin: Origin
}

/// Compile a CSS string into matchable rules, skipping anything unparseable.
func compileRules(_ css: String, origin: Origin) -> [CompiledRule] {
	var rules: [CompiledRule] = []
	for node in parseStylesheet(css, skipComments: true, skipWhitespace: true) {
		guard case .qualifiedRule(let qualified) = node else { continue }
		guard let selectors = parseSelectorList(qualified.prelude) else { continue }
		let declarations = parseDeclarations(qualified.content)
		guard !declarations.isEmpty else { continue }
		for selector in selectors {
			rules.append(CompiledRule(selector: selector, declarations: declarations, origin: origin))
		}
	}
	return rules
}

/// Resolves computed styles for elements given author stylesheets.
public final class StyleResolver {
	private let uaRules: [CompiledRule]
	private let authorRules: [CompiledRule]

	public init(authorStyleSheets: [String] = []) {
		uaRules = compileRules(userAgentCSS, origin: .userAgent)
		authorRules = authorStyleSheets.flatMap { compileRules($0, origin: .author) }
	}

	/// Compute the style of `element`, inheriting from `parent`.
	public func style(for element: SelectorElement, inheriting parent: ComputedStyle, rootFontSize: Double) -> ComputedStyle {
		var style = ComputedStyle.inheriting(from: parent)
		let winners = cascade(for: element)

		// font-size first: em/ex units in other properties resolve against it.
		if let value = winners["font-size"] {
			applyLonghand("font-size", value, to: &style, parent: parent, rootFontSize: rootFontSize)
		}
		// color next: `currentColor` in other properties resolves to it.
		if let value = winners["color"] {
			applyLonghand("color", value, to: &style, parent: parent, rootFontSize: rootFontSize)
		}
		// Initial border color is the element's own `currentColor`.
		style.borderColor = Edges(style.color)

		for (name, value) in winners where name != "font-size" && name != "color" {
			applyLonghand(name, value, to: &style, parent: parent, rootFontSize: rootFontSize)
		}
		return style
	}

	// MARK: - Cascade

	private func cascade(for element: SelectorElement) -> [String: [ComponentValue]] {
		var winnerKey: [String: (level: Int, specificity: Specificity, order: Int)] = [:]
		var winnerValue: [String: [ComponentValue]] = [:]
		var order = 0

		func consider(name: String, value: [ComponentValue], level: Int, specificity: Specificity) {
			let key = (level, specificity, order)
			order += 1
			if let existing = winnerKey[name] {
				let lhs = (existing.level, existing.specificity, existing.order)
				if !(key.0 < lhs.0 || (key.0 == lhs.0 && (key.1 < lhs.1 || (key.1 == lhs.1 && key.2 < lhs.2)))) {
					winnerKey[name] = key
					winnerValue[name] = value
				}
			} else {
				winnerKey[name] = key
				winnerValue[name] = value
			}
		}

		func considerRules(_ rules: [CompiledRule]) {
			for rule in rules where rule.selector.matches(element) {
				for declaration in rule.declarations {
					for longhand in expand(declaration) {
						consider(name: longhand.name, value: longhand.value,
						         level: cascadeLevel(rule.origin, important: declaration.important, inline: false),
						         specificity: rule.selector.specificity)
					}
				}
			}
		}

		considerRules(uaRules)
		considerRules(authorRules)

		if let inlineStyle = element.attributeValue("style") {
			for declaration in parseDeclarations(inlineStyle: inlineStyle) {
				for longhand in expand(declaration) {
					consider(name: longhand.name, value: longhand.value,
					         level: cascadeLevel(.author, important: declaration.important, inline: true),
					         specificity: .zero)
				}
			}
		}

		return winnerValue
	}

	private func cascadeLevel(_ origin: Origin, important: Bool, inline: Bool) -> Int {
		if inline { return important ? 4 : 2 }
		switch (origin, important) {
		case (.userAgent, false): return 0
		case (.author, false): return 1
		case (.author, true): return 3
		case (.userAgent, true): return 5
		}
	}
}

// MARK: - Shorthand expansion

private func significant(_ value: [ComponentValue]) -> [ComponentValue] {
	value.filter { !$0.isWhitespaceOrComment }
}

/// Expand a declaration into longhand `(name, value)` pairs.
private func expand(_ declaration: Declaration) -> [(name: String, value: [ComponentValue])] {
	let name = declaration.lowerName
	let value = declaration.value
	switch name {
	case "margin", "padding":
		return expandBox(prefix: name, value: value)
	case "border-width", "border-style", "border-color":
		let suffix = String(name.dropFirst("border-".count)) // width/style/color
		return expandBox(prefix: "border", suffix: "-" + suffix, value: value)
	case "border", "border-top", "border-right", "border-bottom", "border-left":
		return expandBorder(name: name, value: value)
	case "background":
		// Minimal: pull out a color if present.
		if let color = significant(value).first(where: { parseColor($0) != nil }) {
			return [("background-color", [color])]
		}
		return []
	default:
		return [(name, value)]
	}
}

/// Expand a 1–4 value box shorthand (margin/padding/border-*) into edges.
private func expandBox(prefix: String, suffix: String = "", value: [ComponentValue]) -> [(name: String, value: [ComponentValue])] {
	let values = significant(value).map { [$0] }
	guard !values.isEmpty, values.count <= 4 else { return [] }
	let top: [ComponentValue], right: [ComponentValue], bottom: [ComponentValue], left: [ComponentValue]
	switch values.count {
	case 1: top = values[0]; right = values[0]; bottom = values[0]; left = values[0]
	case 2: top = values[0]; bottom = values[0]; right = values[1]; left = values[1]
	case 3: top = values[0]; right = values[1]; left = values[1]; bottom = values[2]
	default: top = values[0]; right = values[1]; bottom = values[2]; left = values[3]
	}
	return [
		("\(prefix)-top\(suffix)", top),
		("\(prefix)-right\(suffix)", right),
		("\(prefix)-bottom\(suffix)", bottom),
		("\(prefix)-left\(suffix)", left),
	]
}

/// Expand `border`/`border-<side>` into per-edge width/style/color longhands.
private func expandBorder(name: String, value: [ComponentValue]) -> [(name: String, value: [ComponentValue])] {
	let sides: [String]
	if name == "border" {
		sides = ["top", "right", "bottom", "left"]
	} else {
		sides = [String(name.dropFirst("border-".count))]
	}

	var width: ComponentValue? = nil
	var style: ComponentValue? = nil
	var color: ComponentValue? = nil
	for token in significant(value) {
		if case .ident(let ident) = token.token, BorderStyle(rawValue: ident.asciiLowercased) != nil {
			style = token
		} else if isBorderWidthToken(token) {
			width = token
		} else if parseColor(token) != nil {
			color = token
		}
	}

	var result: [(name: String, value: [ComponentValue])] = []
	for side in sides {
		// A border shorthand resets all three; default width to medium, style to none.
		result.append(("border-\(side)-width", width.map { [$0] } ?? [keyword("medium")]))
		result.append(("border-\(side)-style", style.map { [$0] } ?? [keyword("none")]))
		if let color { result.append(("border-\(side)-color", [color])) }
	}
	return result
}

private func isBorderWidthToken(_ token: ComponentValue) -> Bool {
	switch token.token {
	case .dimension, .number:
		return true
	case .ident(let name):
		return ["thin", "medium", "thick"].contains(name.asciiLowercased)
	default:
		return false
	}
}

private func keyword(_ name: String) -> ComponentValue {
	ComponentValue(position: SourcePosition(line: 1, column: 1), token: .ident(name))
}

// MARK: - Longhand application

private func applyLonghand(_ name: String, _ value: [ComponentValue], to style: inout ComputedStyle, parent: ComputedStyle, rootFontSize: Double) {
	if let global = globalKeyword(value) {
		applyGlobal(name, global, to: &style, parent: parent)
		return
	}
	let fontSize = style.fontSize

	switch name {
	case "display":
		if let display = parseDisplay(value) { style.display = display }
	case "color":
		if let color = resolveColor(value, current: parent.color) { style.color = color }
	case "background-color":
		if let token = significant(value).first {
			switch parseColor(token) {
			case .rgba(let rgba): style.backgroundColor = rgba.alpha == 0 ? nil : rgba
			case .currentColor: style.backgroundColor = style.color
			case nil: break
			}
		}
	case "font-family":
		if let families = parseFontFamily(value) { style.fontFamily = families }
	case "font-size":
		if let size = parseFontSize(value, parentFontSize: parent.fontSize, rootFontSize: rootFontSize) { style.fontSize = size }
	case "font-style":
		if let token = significant(value).first, case .ident(let ident) = token.token, let fontStyle = FontStyle(rawValue: ident.asciiLowercased) {
			style.fontStyle = fontStyle
		}
	case "font-weight":
		if let weight = parseFontWeight(value, parent: parent) { style.fontWeight = weight }
	case "line-height":
		if let lineHeight = parseLineHeight(value, fontSize: fontSize, rootFontSize: rootFontSize) { style.lineHeight = lineHeight }
	case "text-align":
		if let token = significant(value).first, case .ident(let ident) = token.token, let align = TextAlign(rawValue: ident.asciiLowercased) {
			style.textAlign = align
		}
	case "white-space":
		if let whiteSpace = parseWhiteSpace(value) { style.whiteSpace = whiteSpace }
	case "text-decoration", "text-decoration-line":
		var underline = false
		var lineThrough = false
		for token in significant(value) {
			if case .ident(let ident) = token.token {
				switch ident.asciiLowercased {
				case "underline": underline = true
				case "line-through": lineThrough = true
				default: break // none, overline, blink, or color/style — ignored
				}
			}
		}
		style.underline = underline
		style.lineThrough = lineThrough
	case "letter-spacing":
		if let token = significant(value).first {
			if case .ident(let ident) = token.token, ident.asciiLowercased == "normal" {
				style.letterSpacing = 0
			} else if let length = parseLength([token], fontSize: fontSize, rootFontSize: rootFontSize), case .px(let pixels) = length {
				style.letterSpacing = pixels
			}
		}
	case "word-spacing":
		if let token = significant(value).first {
			if case .ident(let ident) = token.token, ident.asciiLowercased == "normal" {
				style.wordSpacing = 0
			} else if let length = parseLength([token], fontSize: fontSize, rootFontSize: rootFontSize), case .px(let pixels) = length {
				style.wordSpacing = pixels
			}
		}
	case "list-style-type":
		if let token = significant(value).first, case .ident(let ident) = token.token,
		   let type = parseListStyleType(ident.asciiLowercased) {
			style.listStyleType = type
		}
	case "list-style":
		// Shorthand: take whichever value names a list-style-type.
		for token in significant(value) {
			if case .ident(let ident) = token.token, let type = parseListStyleType(ident.asciiLowercased) {
				style.listStyleType = type
			}
		}
	case "text-indent":
		if let length = parseLength(value, fontSize: fontSize, rootFontSize: rootFontSize), case .px(let pixels) = length {
			style.textIndent = pixels
		}
	case "vertical-align":
		if let token = significant(value).first, case .ident(let ident) = token.token,
		   let align = VerticalAlign(rawValue: ident.asciiLowercased) {
			style.verticalAlign = align
		}
	case "width":
		if let length = parseLength(value, fontSize: fontSize, rootFontSize: rootFontSize) { style.width = length }
	case "height":
		if let length = parseLength(value, fontSize: fontSize, rootFontSize: rootFontSize) { style.height = length }
	case "margin-top", "margin-right", "margin-bottom", "margin-left":
		if let length = parseLength(value, fontSize: fontSize, rootFontSize: rootFontSize) { setEdge(&style.margin, name, length) }
	case "padding-top", "padding-right", "padding-bottom", "padding-left":
		// padding cannot be `auto`; ignore that case.
		if let length = parseLength(value, fontSize: fontSize, rootFontSize: rootFontSize), length != .auto {
			setEdge(&style.padding, name, length)
		}
	case "border-top-width", "border-right-width", "border-bottom-width", "border-left-width":
		if let pixels = parseBorderWidth(value, fontSize: fontSize, rootFontSize: rootFontSize) { setEdge(&style.borderWidth, name, pixels) }
	case "border-top-style", "border-right-style", "border-bottom-style", "border-left-style":
		if let token = significant(value).first, case .ident(let ident) = token.token, let borderStyle = BorderStyle(rawValue: ident.asciiLowercased) {
			setEdge(&style.borderStyle, name, borderStyle)
		}
	case "border-top-color", "border-right-color", "border-bottom-color", "border-left-color":
		if let token = significant(value).first {
			switch parseColor(token) {
			case .rgba(let rgba): setEdge(&style.borderColor, name, rgba)
			case .currentColor: setEdge(&style.borderColor, name, style.color)
			case nil: break
			}
		}
	default:
		break
	}
}

// MARK: - Global keywords

private func globalKeyword(_ value: [ComponentValue]) -> String? {
	let tokens = significant(value)
	guard tokens.count == 1, case .ident(let ident) = tokens[0].token else { return nil }
	let lowered = ident.asciiLowercased
	return ["inherit", "initial", "unset"].contains(lowered) ? lowered : nil
}

private let inheritedProperties: Set<String> = [
	"color", "font-family", "font-size", "font-style", "font-weight",
	"line-height", "text-align", "white-space",
	"text-decoration", "text-decoration-line",
	"letter-spacing", "word-spacing",
	"list-style-type", "list-style",
	"text-indent",
]

/// Map a CSS `list-style-type` keyword (including latin aliases) to the enum.
private func parseListStyleType(_ name: String) -> ListStyleType? {
	switch name {
	case "lower-latin": return .lowerAlpha
	case "upper-latin": return .upperAlpha
	default: return ListStyleType(rawValue: name)
	}
}

private func applyGlobal(_ name: String, _ keyword: String, to style: inout ComputedStyle, parent: ComputedStyle) {
	let inherits = inheritedProperties.contains(name)
	let source: ComputedStyle
	switch keyword {
	case "inherit": source = parent
	case "initial": source = .initial
	default: source = inherits ? parent : .initial // unset
	}
	copyLonghand(name, from: source, into: &style)
}

private func copyLonghand(_ name: String, from source: ComputedStyle, into style: inout ComputedStyle) {
	switch name {
	case "display": style.display = source.display
	case "color": style.color = source.color
	case "background-color": style.backgroundColor = source.backgroundColor
	case "font-family": style.fontFamily = source.fontFamily
	case "font-size": style.fontSize = source.fontSize
	case "font-style": style.fontStyle = source.fontStyle
	case "font-weight": style.fontWeight = source.fontWeight
	case "line-height": style.lineHeight = source.lineHeight
	case "text-align": style.textAlign = source.textAlign
	case "white-space": style.whiteSpace = source.whiteSpace
	case "text-decoration", "text-decoration-line":
		style.underline = source.underline
		style.lineThrough = source.lineThrough
	case "letter-spacing": style.letterSpacing = source.letterSpacing
	case "word-spacing": style.wordSpacing = source.wordSpacing
	case "list-style-type", "list-style": style.listStyleType = source.listStyleType
	case "text-indent": style.textIndent = source.textIndent
	case "vertical-align": style.verticalAlign = source.verticalAlign
	case "width": style.width = source.width
	case "height": style.height = source.height
	case "margin-top", "margin-right", "margin-bottom", "margin-left": setEdge(&style.margin, name, edgeValue(source.margin, name))
	case "padding-top", "padding-right", "padding-bottom", "padding-left": setEdge(&style.padding, name, edgeValue(source.padding, name))
	case "border-top-width", "border-right-width", "border-bottom-width", "border-left-width": setEdge(&style.borderWidth, name, edgeValue(source.borderWidth, name))
	case "border-top-style", "border-right-style", "border-bottom-style", "border-left-style": setEdge(&style.borderStyle, name, edgeValue(source.borderStyle, name))
	case "border-top-color", "border-right-color", "border-bottom-color", "border-left-color": setEdge(&style.borderColor, name, edgeValue(source.borderColor, name))
	default: break
	}
}

// MARK: - Edge helpers

private func edgeIndex(_ name: String) -> Int {
	if name.contains("-top") { return 0 }
	if name.contains("-right") { return 1 }
	if name.contains("-bottom") { return 2 }
	return 3 // left
}

private func setEdge<Value>(_ edges: inout Edges<Value>, _ name: String, _ value: Value) {
	switch edgeIndex(name) {
	case 0: edges.top = value
	case 1: edges.right = value
	case 2: edges.bottom = value
	default: edges.left = value
	}
}

private func edgeValue<Value>(_ edges: Edges<Value>, _ name: String) -> Value {
	switch edgeIndex(name) {
	case 0: return edges.top
	case 1: return edges.right
	case 2: return edges.bottom
	default: return edges.left
	}
}

// MARK: - Value parsers

private func resolveColor(_ value: [ComponentValue], current: RGBA) -> RGBA? {
	guard let token = significant(value).first else { return nil }
	switch parseColor(token) {
	case .rgba(let rgba): return rgba
	case .currentColor: return current
	case nil: return nil
	}
}

private func parseDisplay(_ value: [ComponentValue]) -> Display? {
	guard let token = significant(value).first, case .ident(let ident) = token.token else { return nil }
	switch ident.asciiLowercased {
	case "none": return Display.none
	case "inline": return .inline
	case "block": return .block
	case "inline-block": return .inlineBlock
	case "list-item": return .listItem
	case "table": return .table
	case "table-row": return .tableRow
	case "table-cell": return .tableCell
	case "table-row-group": return .tableRowGroup
	case "table-header-group": return .tableHeaderGroup
	case "table-footer-group": return .tableFooterGroup
	case "table-column": return .tableColumn
	case "table-column-group": return .tableColumnGroup
	case "table-caption": return .tableCaption
	case "flex": return .flex
	case "inline-flex": return .inlineFlex
	case "grid": return .grid
	case "inline-grid": return .inlineGrid
	default: return .other(ident.asciiLowercased)
	}
}

private func parseWhiteSpace(_ value: [ComponentValue]) -> WhiteSpace? {
	guard let token = significant(value).first, case .ident(let ident) = token.token else { return nil }
	switch ident.asciiLowercased {
	case "normal": return .normal
	case "pre": return .pre
	case "nowrap": return .nowrap
	case "pre-wrap": return .preWrap
	case "pre-line": return .preLine
	default: return nil
	}
}

private func parseFontFamily(_ value: [ComponentValue]) -> [String]? {
	let tokens = significant(value)
	guard !tokens.isEmpty else { return nil }
	var families: [String] = []
	var current: [String] = []
	func flush() {
		if !current.isEmpty { families.append(current.joined(separator: " ")); current = [] }
	}
	for token in tokens {
		if token.isLiteral(",") {
			flush()
		} else if case .string(let string) = token.token {
			current = [string]
		} else if case .ident(let ident) = token.token {
			current.append(ident)
		}
	}
	flush()
	return families.isEmpty ? nil : families
}

private func parseFontWeight(_ value: [ComponentValue], parent: ComputedStyle) -> Int? {
	guard let token = significant(value).first else { return nil }
	switch token.token {
	case .ident(let ident):
		switch ident.asciiLowercased {
		case "normal": return 400
		case "bold": return 700
		case "bolder": return parent.fontWeight < 400 ? 400 : (parent.fontWeight < 600 ? 700 : 900)
		case "lighter": return parent.fontWeight < 600 ? 100 : (parent.fontWeight < 800 ? 400 : 700)
		default: return nil
		}
	case .number(_, let int, _):
		if let weight = int { return min(1000, max(1, weight)) }
		return nil
	default:
		return nil
	}
}

private func parseFontSize(_ value: [ComponentValue], parentFontSize: Double, rootFontSize: Double) -> Double? {
	guard let token = significant(value).first else { return nil }
	switch token.token {
	case .ident(let ident):
		switch ident.asciiLowercased {
		case "xx-small": return 9
		case "x-small": return 10
		case "small": return 13
		case "medium": return 16
		case "large": return 18
		case "x-large": return 24
		case "xx-large": return 32
		case "larger": return parentFontSize * 1.2
		case "smaller": return parentFontSize / 1.2
		default: return nil
		}
	case .percentage(let percent, _, _):
		return parentFontSize * percent / 100
	case .dimension, .number:
		if let length = parseLength([token], fontSize: parentFontSize, rootFontSize: rootFontSize), case .px(let pixels) = length {
			return pixels
		}
		return nil
	default:
		return nil
	}
}

private func parseLineHeight(_ value: [ComponentValue], fontSize: Double, rootFontSize: Double) -> LineHeight? {
	guard let token = significant(value).first else { return nil }
	switch token.token {
	case .ident(let ident) where ident.asciiLowercased == "normal":
		return .normal
	case .number(let number, _, _):
		return .number(number)
	case .percentage(let percent, _, _):
		return .length(fontSize * percent / 100)
	case .dimension:
		if let length = parseLength([token], fontSize: fontSize, rootFontSize: rootFontSize), case .px(let pixels) = length {
			return .length(pixels)
		}
		return nil
	default:
		return nil
	}
}

private func parseBorderWidth(_ value: [ComponentValue], fontSize: Double, rootFontSize: Double) -> Double? {
	guard let token = significant(value).first else { return nil }
	if case .ident(let ident) = token.token {
		switch ident.asciiLowercased {
		case "thin": return 1
		case "medium": return 3
		case "thick": return 5
		default: return nil
		}
	}
	if let length = parseLength([token], fontSize: fontSize, rootFontSize: rootFontSize), case .px(let pixels) = length {
		return pixels
	}
	return nil
}

/// Parse a single length/percentage/auto value, resolving absolute and
/// font-relative units to pixels.
public func parseLength(_ value: [ComponentValue], fontSize: Double, rootFontSize: Double) -> Length? {
	guard let token = (value.first { !$0.isWhitespaceOrComment }) else { return nil }
	switch token.token {
	case .dimension(let amount, _, _, let unit):
		let lowered = unit.asciiLowercased
		if let factor = absoluteLengthFactor(lowered) {
			return .px(amount * factor)
		}
		switch lowered {
		case "em": return .px(amount * fontSize)
		case "rem": return .px(amount * rootFontSize)
		case "ex": return .px(amount * fontSize * 0.5)
		case "ch": return .px(amount * fontSize * 0.5)
		default: return nil
		}
	case .number(let amount, _, _):
		return amount == 0 ? .px(0) : nil
	case .percentage(let percent, _, _):
		return .percent(percent)
	case .ident(let ident) where ident.asciiLowercased == "auto":
		return .auto
	default:
		return nil
	}
}

/// The pixel-per-unit factor for absolute CSS units (96px == 1in), or `nil`.
public func absoluteLengthFactor(_ unit: String) -> Double? {
	switch unit {
	case "px": return 1
	case "pt": return 96.0 / 72.0
	case "pc": return 16
	case "in": return 96
	case "cm": return 96.0 / 2.54
	case "mm": return 96.0 / 25.4
	case "q": return 96.0 / 25.4 / 4
	default: return nil
	}
}
