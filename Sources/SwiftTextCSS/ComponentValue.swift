//  ComponentValue.swift
//  SwiftTextCSS
//
//  The CSS abstract syntax tree: component values (tokens and blocks) plus the
//  rule/declaration nodes the parser produces. A faithful Swift port of
//  tinycss2's `ast.py` (https://github.com/Kozea/tinycss2, BSD-3-Clause),
//  implementing CSS Syntax Level 3.

import Foundation

/// A 1-based source position within a CSS string.
public struct SourcePosition: Equatable, Sendable {
	public let line: Int
	public let column: Int

	public init(line: Int, column: Int) {
		self.line = line
		self.column = column
	}
}

/// A CSS component value: a single token or a nested block/function.
public indirect enum CSSToken: Equatable, Sendable {
	case whitespace(String)
	case comment(String)
	/// A single-character (or short operator) literal such as `;`, `:`, `,`,
	/// `!`, `+`, `>`, `~=`, `<!--`.
	case literal(String)
	case ident(String)
	case atKeyword(String)
	case hash(String, isIdentifier: Bool)
	case string(String)
	case url(String)
	case number(Double, int: Int?, representation: String)
	case percentage(Double, int: Int?, representation: String)
	case dimension(Double, int: Int?, representation: String, unit: String)
	case parentheses([ComponentValue])
	case squareBrackets([ComponentValue])
	case curlyBrackets([ComponentValue])
	case function(name: String, arguments: [ComponentValue])
	case unicodeRange(start: UInt32, end: UInt32)
	case error(kind: String, message: String)

	/// The tinycss2 `type` string for this node, used by the parser.
	public var typeName: String {
		switch self {
		case .whitespace: return "whitespace"
		case .comment: return "comment"
		case .literal: return "literal"
		case .ident: return "ident"
		case .atKeyword: return "at-keyword"
		case .hash: return "hash"
		case .string: return "string"
		case .url: return "url"
		case .number: return "number"
		case .percentage: return "percentage"
		case .dimension: return "dimension"
		case .parentheses: return "() block"
		case .squareBrackets: return "[] block"
		case .curlyBrackets: return "{} block"
		case .function: return "function"
		case .unicodeRange: return "unicode-range"
		case .error: return "error"
		}
	}
}

/// A component value paired with its source position.
public struct ComponentValue: Equatable, Sendable {
	public let position: SourcePosition
	public let token: CSSToken

	public init(position: SourcePosition, token: CSSToken) {
		self.position = position
		self.token = token
	}

	public var type: String { token.typeName }

	public var isWhitespaceOrComment: Bool {
		switch token {
		case .whitespace, .comment: return true
		default: return false
		}
	}

	/// Whether this is a literal token equal to `string` (e.g. `;`, `:`).
	public func isLiteral(_ string: String) -> Bool {
		if case .literal(let value) = token { return value == string }
		return false
	}

	/// The identifier value, if this is an ident token.
	public var identValue: String? {
		if case .ident(let value) = token { return value }
		return nil
	}

	/// The ASCII-lowercased identifier value, if this is an ident token.
	public var identLowerValue: String? {
		identValue?.asciiLowercased
	}

	/// The nested content if this value is a `{}`, `[]` or `()` block.
	public var blockContent: [ComponentValue]? {
		switch token {
		case .parentheses(let content), .squareBrackets(let content), .curlyBrackets(let content):
			return content
		default:
			return nil
		}
	}
}

// MARK: - Rules and declarations

/// A qualified rule: a prelude (e.g. a selector list) followed by a `{}` block.
public struct QualifiedRule: Equatable, Sendable {
	public let position: SourcePosition
	public let prelude: [ComponentValue]
	public let content: [ComponentValue]
}

/// An at-rule such as `@media` or `@page`.
public struct AtRule: Equatable, Sendable {
	public let position: SourcePosition
	public let atKeyword: String
	public let lowerAtKeyword: String
	public let prelude: [ComponentValue]
	/// The `{}` block content, or `nil` if the rule ended with `;`.
	public let content: [ComponentValue]?
}

/// A single `name: value` declaration.
public struct Declaration: Equatable, Sendable {
	public let position: SourcePosition
	public let name: String
	public let lowerName: String
	public let value: [ComponentValue]
	public let important: Bool
}

/// A node produced when parsing a stylesheet or a block's contents.
public enum CSSNode: Equatable, Sendable {
	case qualifiedRule(QualifiedRule)
	case atRule(AtRule)
	case declaration(Declaration)
	case comment(SourcePosition, String)
	case whitespace(SourcePosition, String)
	case error(SourcePosition, kind: String, message: String)
}

extension String {
	/// Lowercase only ASCII A–Z, matching CSS's `ascii_lower`.
	var asciiLowercased: String {
		String(unicodeScalars.map { scalar -> Character in
			(scalar >= "A" && scalar <= "Z")
				? Character(Unicode.Scalar(scalar.value + 0x20)!)
				: Character(scalar)
		})
	}
}
