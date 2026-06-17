//  CSSParser.swift
//  SwiftTextCSS
//
//  Stylesheet, rule and declaration parsing: a Swift port of tinycss2's
//  `parser.py`, implementing CSS Syntax Level 3.

import Foundation

/// A forward cursor over a list of component values, with the ability to skip
/// insignificant (whitespace/comment) tokens and to rewind.
struct TokenStream {
	let tokens: [ComponentValue]
	var index: Int = 0

	init(_ tokens: [ComponentValue]) {
		self.tokens = tokens
	}

	mutating func next() -> ComponentValue? {
		guard index < tokens.count else { return nil }
		defer { index += 1 }
		return tokens[index]
	}

	mutating func nextSignificant() -> ComponentValue? {
		while let token = next() {
			if !token.isWhitespaceOrComment { return token }
		}
		return nil
	}
}

// MARK: - Public entry points

/// Parse a stylesheet, ignoring top-level `<!--`/`-->` (a `<style>` quirk).
public func parseStylesheet(_ input: String, skipComments: Bool = false, skipWhitespace: Bool = false) -> [CSSNode] {
	var stream = TokenStream(tokenizeComponentValues(input, skipComments: skipComments))
	var result: [CSSNode] = []
	while let token = stream.next() {
		switch token.token {
		case .whitespace(let value):
			if !skipWhitespace { result.append(.whitespace(token.position, value)) }
		case .comment(let value):
			if !skipComments { result.append(.comment(token.position, value)) }
		default:
			if token.isLiteral("<!--") || token.isLiteral("-->") { continue }
			result.append(consumeRule(first: token, stream: &stream))
		}
	}
	return result
}

/// Parse a block's contents (declarations and nested rules), from a string.
public func parseBlocksContents(_ input: String, skipComments: Bool = false, skipWhitespace: Bool = false) -> [CSSNode] {
	parseBlocksContents(tokenizeComponentValues(input, skipComments: skipComments), skipComments: skipComments, skipWhitespace: skipWhitespace)
}

/// Parse a block's contents from an existing list of component values (e.g. a
/// rule's `{}` block or an element's `style` attribute).
public func parseBlocksContents(_ tokens: [ComponentValue], skipComments: Bool = false, skipWhitespace: Bool = false) -> [CSSNode] {
	var stream = TokenStream(tokens)
	var result: [CSSNode] = []
	while let token = stream.next() {
		switch token.token {
		case .whitespace(let value):
			if !skipWhitespace { result.append(.whitespace(token.position, value)) }
		case .comment(let value):
			if !skipComments { result.append(.comment(token.position, value)) }
		case .atKeyword:
			result.append(consumeAtRule(token, &stream))
		default:
			if token.isLiteral(";") { continue }
			result.append(consumeBlocksContent(first: token, stream: &stream))
		}
	}
	return result
}

/// Parse a single declaration from a string (e.g. an `@supports` test).
public func parseOneDeclaration(_ input: String, skipComments: Bool = false) -> CSSNode {
	var stream = TokenStream(tokenizeComponentValues(input, skipComments: skipComments))
	guard let first = stream.nextSignificant() else {
		return .error(SourcePosition(line: 1, column: 1), kind: "empty", message: "Input is empty")
	}
	return parseDeclaration(first: first, stream: &stream)
}

/// Convenience: extract just the declarations from a block's contents,
/// discarding nested rules, errors, whitespace and comments.
public func parseDeclarations(_ tokens: [ComponentValue]) -> [Declaration] {
	parseBlocksContents(tokens, skipComments: true, skipWhitespace: true).compactMap { node in
		if case .declaration(let declaration) = node { return declaration }
		return nil
	}
}

/// Convenience: extract declarations from an inline `style` attribute string.
public func parseDeclarations(inlineStyle: String) -> [Declaration] {
	parseDeclarations(tokenizeComponentValues(inlineStyle, skipComments: true))
}

// MARK: - Rule consumption

private func consumeRule(first: ComponentValue, stream: inout TokenStream) -> CSSNode {
	if case .atKeyword = first.token {
		return consumeAtRule(first, &stream)
	}
	return consumeQualifiedRule(first, &stream, stopToken: nil)
}

private func consumeAtRule(_ atKeyword: ComponentValue, _ stream: inout TokenStream) -> CSSNode {
	guard case .atKeyword(let name) = atKeyword.token else {
		return .error(atKeyword.position, kind: "invalid", message: "Expected at-keyword")
	}
	var prelude: [ComponentValue] = []
	var content: [ComponentValue]? = nil
	while let token = stream.next() {
		if token.type == "{} block" {
			content = token.blockContent
			break
		} else if token.isLiteral(";") {
			break
		}
		prelude.append(token)
	}
	return .atRule(AtRule(
		position: atKeyword.position,
		atKeyword: name,
		lowerAtKeyword: name.asciiLowercased,
		prelude: prelude,
		content: content))
}

private func ruleError(_ token: ComponentValue, _ name: String) -> CSSNode {
	.error(token.position, kind: "invalid", message: "\(name) reached before {} block for a qualified rule.")
}

private func consumeQualifiedRule(_ first: ComponentValue, _ stream: inout TokenStream, stopToken: String?) -> CSSNode {
	func isStop(_ token: ComponentValue) -> Bool {
		if let stop = stopToken { return token.isLiteral(stop) }
		return false
	}

	if isStop(first) {
		return ruleError(first, "Stop token")
	}

	var prelude: [ComponentValue]
	let block: ComponentValue
	if first.type == "{} block" {
		prelude = []
		block = first
	} else {
		prelude = [first]
		var found: ComponentValue? = nil
		while let token = stream.next() {
			if isStop(token) {
				return ruleError(token, "Stop token")
			}
			if token.type == "{} block" {
				found = token
				break
			}
			prelude.append(token)
		}
		guard let foundBlock = found else {
			return ruleError(prelude.last ?? first, "EOF")
		}
		block = foundBlock
	}
	return .qualifiedRule(QualifiedRule(
		position: first.position,
		prelude: prelude,
		content: block.blockContent ?? []))
}

private func consumeBlocksContent(first: ComponentValue, stream: inout TokenStream) -> CSSNode {
	let savedIndex = stream.index
	var declarationTokens: [ComponentValue] = []
	if !first.isLiteral(";") && first.type != "{} block" {
		while let token = stream.next() {
			if token.isLiteral(";") { break }
			declarationTokens.append(token)
			if token.type == "{} block" { break }
		}
	}

	var subStream = TokenStream(declarationTokens)
	let declaration = parseDeclaration(first: first, stream: &subStream)
	if case .declaration = declaration {
		return declaration
	}

	// Not a valid declaration: rewind and reparse as a nested qualified rule.
	stream.index = savedIndex
	return consumeQualifiedRule(first, &stream, stopToken: ";")
}

// MARK: - Declaration parsing

private func consumeRemnants(_ stream: inout TokenStream, nested: Bool) {
	while let token = stream.next() {
		if token.isLiteral(";") { return }
		if nested && token.isLiteral("}") { return }
	}
}

func parseDeclaration(first: ComponentValue, stream: inout TokenStream, nested: Bool = true) -> CSSNode {
	guard case .ident(let name) = first.token else {
		consumeRemnants(&stream, nested: nested)
		return .error(first.position, kind: "invalid", message: "Expected <ident> for declaration name, got \(first.type).")
	}

	guard let colon = stream.nextSignificant() else {
		consumeRemnants(&stream, nested: nested)
		return .error(first.position, kind: "invalid", message: "Expected ':' after declaration name, got EOF")
	}
	if !colon.isLiteral(":") {
		consumeRemnants(&stream, nested: nested)
		return .error(colon.position, kind: "invalid", message: "Expected ':' after declaration name.")
	}

	var value: [ComponentValue] = []
	var state = "value"
	var bangPosition: Int? = nil
	var containsNonWhitespace = false
	var containsSimpleBlock = false

	while let token = stream.next() {
		if state == "value" && token.isLiteral("!") {
			state = "bang"
			bangPosition = value.count
		} else if state == "bang", case .ident(let ident) = token.token, ident.asciiLowercased == "important" {
			state = "important"
		} else if !token.isWhitespaceOrComment {
			state = "value"
			if token.type == "{} block" {
				if containsNonWhitespace { containsSimpleBlock = true } else { containsNonWhitespace = true }
			} else {
				containsNonWhitespace = true
			}
		}
		value.append(token)
	}

	if state == "important", let bang = bangPosition {
		value.removeSubrange(bang...)
	}

	if containsSimpleBlock && containsNonWhitespace {
		return .error(colon.position, kind: "invalid", message: "Declaration contains {} block")
	}

	return .declaration(Declaration(
		position: first.position,
		name: name,
		lowerName: name.asciiLowercased,
		value: value,
		important: state == "important"))
}
