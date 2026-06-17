//  SelectorParser.swift
//  SwiftTextCSS
//
//  Parses a selector list (a rule's prelude) into complex selectors with
//  specificity. Supports type/universal/id/class/attribute selectors, the four
//  combinators, and a subset of structural pseudo-classes. Unsupported
//  pseudo-classes/elements are kept but never match.

import Foundation

/// Parse a comma-separated selector list from component values, or `nil` if any
/// selector is malformed.
public func parseSelectorList(_ tokens: [ComponentValue]) -> [ComplexSelector]? {
	var groups: [[ComponentValue]] = [[]]
	for token in tokens {
		if token.isLiteral(",") {
			groups.append([])
		} else {
			groups[groups.count - 1].append(token)
		}
	}
	var result: [ComplexSelector] = []
	for group in groups {
		guard let complex = parseComplexSelector(group) else { return nil }
		result.append(complex)
	}
	return result
}

/// Parse a selector list from a string.
public func parseSelectorList(_ css: String) -> [ComplexSelector]? {
	parseSelectorList(tokenizeComponentValues(css, skipComments: true))
}

private func parseComplexSelector(_ tokens: [ComponentValue]) -> ComplexSelector? {
	var pos = 0
	let count = tokens.count

	while pos < count, tokens[pos].type == "whitespace" { pos += 1 }
	guard let first = parseCompoundSelector(tokens, &pos) else { return nil }

	var compounds = [first]
	var combinators: [Combinator] = []

	while pos < count {
		var sawWhitespace = false
		while pos < count, tokens[pos].type == "whitespace" { sawWhitespace = true; pos += 1 }
		if pos >= count { break } // trailing whitespace

		let combinator: Combinator
		if tokens[pos].isLiteral(">") { combinator = .child; pos += 1 }
		else if tokens[pos].isLiteral("+") { combinator = .nextSibling; pos += 1 }
		else if tokens[pos].isLiteral("~") { combinator = .subsequentSibling; pos += 1 }
		else if sawWhitespace { combinator = .descendant }
		else { return nil }

		while pos < count, tokens[pos].type == "whitespace" { pos += 1 }
		guard let next = parseCompoundSelector(tokens, &pos) else { return nil }
		combinators.append(combinator)
		compounds.append(next)
	}

	guard let rightmost = compounds.last else { return nil }
	var ancestors: [(Combinator, CompoundSelector)] = []
	var index = compounds.count - 1
	while index > 0 {
		ancestors.append((combinators[index - 1], compounds[index - 1]))
		index -= 1
	}
	return ComplexSelector(rightmost: rightmost, ancestors: ancestors, specificity: computeSpecificity(compounds))
}

private func parseCompoundSelector(_ tokens: [ComponentValue], _ pos: inout Int) -> CompoundSelector? {
	var compound = CompoundSelector()
	let count = tokens.count

	loop: while pos < count {
		let token = tokens[pos]
		switch token.token {
		case .ident(let name):
			if compound.type != nil || compound.universal { return nil }
			compound.type = name.asciiLowercased
			pos += 1
		case .literal("*"):
			if compound.type != nil || compound.universal { return nil }
			compound.universal = true
			pos += 1
		case .hash(let value, _):
			compound.ids.append(value)
			pos += 1
		case .literal("."):
			pos += 1
			guard pos < count, case .ident(let cls) = tokens[pos].token else { return nil }
			compound.classes.append(cls)
			pos += 1
		case .squareBrackets(let content):
			guard let attribute = parseAttributeSelector(content) else { return nil }
			compound.attributes.append(attribute)
			pos += 1
		case .literal(":"):
			pos += 1
			var isElement = false
			if pos < count, tokens[pos].isLiteral(":") { isElement = true; pos += 1 }
			guard pos < count else { return nil }
			switch tokens[pos].token {
			case .ident(let name):
				applyPseudo(name.asciiLowercased, isElement: isElement, to: &compound)
				pos += 1
			case .function:
				compound.hasUnsupportedPseudo = true // functional pseudo, unsupported for now
				pos += 1
			default:
				return nil
			}
		default:
			break loop
		}
	}

	return compound.isEmpty ? nil : compound
}

private func applyPseudo(_ name: String, isElement: Bool, to compound: inout CompoundSelector) {
	if isElement {
		compound.hasUnsupportedPseudo = true
		return
	}
	switch name {
	case "root": compound.pseudoClasses.append(.root)
	case "first-child": compound.pseudoClasses.append(.firstChild)
	case "last-child": compound.pseudoClasses.append(.lastChild)
	case "only-child": compound.pseudoClasses.append(.onlyChild)
	default: compound.hasUnsupportedPseudo = true
	}
}

private func parseAttributeSelector(_ content: [ComponentValue]) -> AttributeSelector? {
	let significant = content.filter { !$0.isWhitespaceOrComment }
	guard let first = significant.first, case .ident(let name) = first.token else { return nil }
	if significant.count == 1 {
		return AttributeSelector(name: name, match: .exists, value: "")
	}
	guard significant.count == 3, case .literal(let op) = significant[1].token else { return nil }
	let match: AttributeSelector.Match
	switch op {
	case "=": match = .equals
	case "~=": match = .includes
	case "|=": match = .dashMatch
	case "^=": match = .prefix
	case "$=": match = .suffix
	case "*=": match = .substring
	default: return nil
	}
	let value: String
	switch significant[2].token {
	case .ident(let identValue): value = identValue
	case .string(let stringValue): value = stringValue
	default: return nil
	}
	return AttributeSelector(name: name, match: match, value: value)
}

private func computeSpecificity(_ compounds: [CompoundSelector]) -> Specificity {
	var a = 0, b = 0, c = 0
	for compound in compounds {
		a += compound.ids.count
		b += compound.classes.count + compound.attributes.count + compound.pseudoClasses.count
		if compound.type != nil { c += 1 }
	}
	return Specificity(a, b, c)
}
