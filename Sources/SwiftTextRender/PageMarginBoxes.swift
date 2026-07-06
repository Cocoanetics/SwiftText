//  PageMarginBoxes.swift
//  SwiftTextRender
//
//  CSS Paged Media margin boxes: `@page { @top-center { content: ... } }` and
//  friends, for running headers/footers and `counter(page)`/`counter(pages)`
//  page numbers. Parsing collects the six side (non-corner) margin boxes;
//  resolution turns them into plain text + style, ready for `Painter` to draw
//  directly in page space once the final page count is known.

import Foundation
import SwiftTextCSS

/// The CSS Paged Media margin boxes this engine supports (the three per edge
/// on the top and bottom edges; corners and the left/right edges are not).
enum MarginBoxArea: String, CaseIterable {
	case topLeft = "top-left"
	case topCenter = "top-center"
	case topRight = "top-right"
	case bottomLeft = "bottom-left"
	case bottomCenter = "bottom-center"
	case bottomRight = "bottom-right"

	var isTop: Bool {
		switch self {
		case .topLeft, .topCenter, .topRight: return true
		case .bottomLeft, .bottomCenter, .bottomRight: return false
		}
	}

	/// The alignment implied by the box's position, absent an explicit
	/// `text-align` in the rule.
	var impliedTextAlign: TextAlign {
		switch self {
		case .topLeft, .bottomLeft: return .left
		case .topCenter, .bottomCenter: return .center
		case .topRight, .bottomRight: return .right
		}
	}
}

/// A `@page` pseudo-class selector: `:first`, `:left`, `:right`. Anything else
/// (`:blank`, named pages) is recognized but never matches — safer than
/// silently applying an unsupported rule to every page.
struct PageSelector {
	var first = false
	var side: String? // "left" or "right"
	var unsupported = false

	func matches(pageIndex: Int) -> Bool {
		if unsupported { return false }
		if first, pageIndex != 0 { return false }
		if let side {
			let isRightPage = pageIndex.isMultiple(of: 2) // page 1 (index 0) is recto/right
			if (side == "right") != isRightPage { return false }
		}
		return true
	}
}

/// One `@page` rule's margin-box declarations, keyed by box name, plus the
/// selector that decides which pages it applies to.
struct PageRule {
	let selector: PageSelector
	let marginBoxes: [MarginBoxArea: [Declaration]]
}

/// A margin box resolved for a specific page: literal display text (counters
/// already substituted) and the style to paint it with.
struct ResolvedMarginBox {
	let area: MarginBoxArea
	let text: String
	let style: ComputedStyle
}

// MARK: - Parsing

/// Collect every `@page` rule's margin-box declarations across `sheets`.
/// Rules with no margin boxes (only `size`/`margin`) are skipped — those are
/// handled separately for page geometry.
func parsePageRules(_ sheets: [String]) -> [PageRule] {
	var rules: [PageRule] = []
	for sheet in sheets {
		for node in parseStylesheet(sheet, skipComments: true, skipWhitespace: true) {
			guard case .atRule(let atRule) = node, atRule.lowerAtKeyword == "page", let content = atRule.content else { continue }
			var marginBoxes: [MarginBoxArea: [Declaration]] = [:]
			for child in parseBlocksContents(content, skipComments: true, skipWhitespace: true) {
				guard case .atRule(let nested) = child,
				      let area = MarginBoxArea(rawValue: nested.lowerAtKeyword),
				      let nestedContent = nested.content else { continue }
				marginBoxes[area, default: []].append(contentsOf: parseDeclarations(nestedContent))
			}
			guard !marginBoxes.isEmpty else { continue }
			rules.append(PageRule(selector: parsePageSelector(atRule.prelude), marginBoxes: marginBoxes))
		}
	}
	return rules
}

private func parsePageSelector(_ prelude: [ComponentValue]) -> PageSelector {
	var selector = PageSelector()
	let tokens = prelude.filter { !$0.isWhitespaceOrComment }
	var index = 0
	while index < tokens.count {
		if tokens[index].isLiteral(":"), index + 1 < tokens.count, case .ident(let ident) = tokens[index + 1].token {
			switch ident.lowercased() {
			case "first": selector.first = true
			case "left", "right": selector.side = ident.lowercased()
			default: selector.unsupported = true // e.g. :blank
			}
			index += 2
		} else {
			selector.unsupported = true // e.g. a named page
			index += 1
		}
	}
	return selector
}

/// One piece of a margin box's `content` value.
private enum ContentPart {
	case literal(String)
	case pageCounter(style: ListStyleType)
	case pagesCounter(style: ListStyleType)
}

/// Parse a `content` value into literal/counter parts. `normal`/`none` (the
/// default — no box is generated) and unparseable values both yield `[]`.
private func parseContentValue(_ value: [ComponentValue]) -> [ContentPart] {
	let tokens = value.filter { !$0.isWhitespaceOrComment }
	guard !tokens.isEmpty else { return [] }
	if tokens.count == 1, case .ident(let ident) = tokens[0].token, ["normal", "none"].contains(ident.lowercased()) {
		return []
	}

	var parts: [ContentPart] = []
	for token in tokens {
		switch token.token {
		case .string(let string):
			parts.append(.literal(string))
		case .function(let name, let arguments) where name.lowercased() == "counter":
			let args = arguments.filter { !$0.isWhitespaceOrComment && !$0.isLiteral(",") }
			guard let first = args.first, case .ident(let counterName) = first.token else { continue }
			var style = ListStyleType.decimal
			if args.count > 1, case .ident(let styleName) = args[1].token, let parsed = ListStyleType(rawValue: styleName.lowercased()) {
				style = parsed
			}
			switch counterName.lowercased() {
			case "page": parts.append(.pageCounter(style: style))
			case "pages": parts.append(.pagesCounter(style: style))
			default: break // other named counters aren't tracked by this engine
			}
		default:
			break // attr(), url(), quotes, etc. — not supported
		}
	}
	return parts
}

private func renderedText(_ parts: [ContentPart], pageIndex: Int, totalPages: Int) -> String {
	parts.map { part in
		switch part {
		case .literal(let string): return string
		case .pageCounter(let style): return BoxTreeBuilder.formatOrdinal(pageIndex + 1, as: style)
		case .pagesCounter(let style): return BoxTreeBuilder.formatOrdinal(totalPages, as: style)
		}
	}.joined()
}

// MARK: - Resolution

/// Resolve every margin box that applies to page `pageIndex` (0-based), given
/// the final page count. Declarations from every matching rule are merged per
/// box, in source order, so an unqualified base rule and a later `:first`
/// override can each set only the properties they care about (e.g. `:first`
/// clearing `content` while the base rule's `font-size` still applies).
func resolveMarginBoxes(_ rules: [PageRule], pageIndex: Int, totalPages: Int, rootStyle: ComputedStyle, rootFontSize: Double) -> [ResolvedMarginBox] {
	let matching = rules.filter { $0.selector.matches(pageIndex: pageIndex) }
	guard !matching.isEmpty else { return [] }

	var result: [ResolvedMarginBox] = []
	for area in MarginBoxArea.allCases {
		let declarations = matching.flatMap { $0.marginBoxes[area] ?? [] }
		guard let contentDeclaration = declarations.last(where: { $0.lowerName == "content" }) else { continue }
		let parts = parseContentValue(contentDeclaration.value)
		guard !parts.isEmpty else { continue }
		let text = renderedText(parts, pageIndex: pageIndex, totalPages: totalPages)
		guard !text.isEmpty else { continue }

		// The box's own parent for inheritance: the document root's style (per
		// spec, margin boxes inherit from the page context, not the element
		// under the cursor), with its position's implied alignment as the
		// default `text-align` — an explicit `text-align` in the rule still wins.
		var parent = rootStyle
		parent.textAlign = area.impliedTextAlign
		let style = applyDeclarations(declarations.filter { $0.lowerName != "content" }, inheriting: parent, rootFontSize: rootFontSize)
		result.append(ResolvedMarginBox(area: area, text: text, style: style))
	}
	return result
}
