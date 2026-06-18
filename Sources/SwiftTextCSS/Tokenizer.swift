//  Tokenizer.swift
//  SwiftTextCSS
//
//  CSS tokenizer: a Swift port of tinycss2's `tokenizer.py`. Produces a list of
//  component values (tokens and nested blocks) per CSS Syntax Level 3.

import Foundation

/// Tokenize a CSS string into a list of top-level component values.
public func tokenizeComponentValues(_ css: String, skipComments: Bool = false) -> [ComponentValue] {
	Tokenizer(css: css, skipComments: skipComments).tokenize()
}

private func isWhitespace(_ s: Unicode.Scalar) -> Bool { s == " " || s == "\n" || s == "\t" }
private func isDigit(_ s: Unicode.Scalar) -> Bool { s >= "0" && s <= "9" }
private func isHex(_ s: Unicode.Scalar) -> Bool {
	isDigit(s) || (s >= "a" && s <= "f") || (s >= "A" && s <= "F")
}
private func isNameStart(_ s: Unicode.Scalar) -> Bool {
	(s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || s == "_" || s.value > 0x7F
}
private func isNameChar(_ s: Unicode.Scalar) -> Bool {
	isNameStart(s) || isDigit(s) || s == "-"
}

private final class Tokenizer {
	private let scalars: [Unicode.Scalar]
	private let length: Int
	private let skipComments: Bool
	private let newlineIndices: [Int]
	private var pos = 0

	init(css: String, skipComments: Bool) {
		// Preprocessing per the spec: normalize nulls and newlines.
		let normalized = css
			.replacingOccurrences(of: "\u{0}", with: "\u{FFFD}")
			.replacingOccurrences(of: "\r\n", with: "\n")
			.replacingOccurrences(of: "\r", with: "\n")
			.replacingOccurrences(of: "\u{C}", with: "\n")
		scalars = Array(normalized.unicodeScalars)
		length = scalars.count
		self.skipComments = skipComments
		var newlines: [Int] = []
		for (index, scalar) in scalars.enumerated() where scalar == "\n" {
			newlines.append(index)
		}
		newlineIndices = newlines
	}

	func tokenize() -> [ComponentValue] {
		consumeList(endChar: nil)
	}

	// MARK: - Position

	private func position(at p: Int) -> SourcePosition {
		// Number of newlines strictly before p.
		var low = 0
		var high = newlineIndices.count
		while low < high {
			let mid = (low + high) / 2
			if newlineIndices[mid] < p { low = mid + 1 } else { high = mid }
		}
		let lastNewline = low > 0 ? newlineIndices[low - 1] : -1
		return SourcePosition(line: 1 + low, column: p - lastNewline)
	}

	// MARK: - Scanning helpers

	private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
		let index = pos + offset
		return index < length ? scalars[index] : nil
	}

	private func startsWith(_ string: String, at offset: Int = 0) -> Bool {
		let target = Array(string.unicodeScalars)
		guard pos + offset + target.count <= length else { return false }
		for (index, scalar) in target.enumerated() where scalars[pos + offset + index] != scalar {
			return false
		}
		return true
	}

	private func string(from start: Int, to end: Int) -> String {
		var view = String.UnicodeScalarView()
		view.append(contentsOf: scalars[start ..< end])
		return String(view)
	}

	// MARK: - Main loop

	private func consumeList(endChar: Unicode.Scalar?) -> [ComponentValue] {
		var tokens: [ComponentValue] = []

		func append(_ token: CSSToken, at start: Int) {
			tokens.append(ComponentValue(position: position(at: start), token: token))
		}

		while pos < length {
			let start = pos
			let c = scalars[pos]

			if isWhitespace(c) {
				pos += 1
				while let n = peek(), isWhitespace(n) { pos += 1 }
				append(.whitespace(string(from: start, to: pos)), at: start)
			} else if c == "U" || c == "u", pos + 2 < length, scalars[pos + 1] == "+",
			          isHex(scalars[pos + 2]) || scalars[pos + 2] == "?" {
				let range = consumeUnicodeRange(from: pos + 2)
				append(.unicodeRange(start: range.start, end: range.end), at: start)
			} else if startsWith("-->") {
				append(.literal("-->"), at: start)
				pos += 3
			} else if isIdentStart(at: pos) {
				let value = consumeIdent()
				if peek() != "(" {
					append(.ident(value), at: start)
				} else {
					pos += 1 // skip '('
					if value.asciiLowercased == "url", !nextNonSpaceIsQuote() {
						let result = consumeURL()
						if let url = result.value {
							append(.url(url), at: start)
						}
						if let error = result.error {
							append(.error(kind: error.0, message: error.1), at: start)
						}
					} else {
						let arguments = consumeList(endChar: ")")
						append(.function(name: value, arguments: arguments), at: start)
					}
				}
			} else if let number = consumeNumber() {
				if isIdentStart(at: pos) {
					let unit = consumeIdent()
					append(.dimension(number.value, int: number.int, representation: number.representation, unit: unit), at: start)
				} else if peek() == "%" {
					pos += 1
					append(.percentage(number.value, int: number.int, representation: number.representation), at: start)
				} else {
					append(.number(number.value, int: number.int, representation: number.representation), at: start)
				}
			} else if c == "@" {
				pos += 1
				if pos < length, isIdentStart(at: pos) {
					append(.atKeyword(consumeIdent()), at: start)
				} else {
					append(.literal("@"), at: start)
				}
			} else if c == "#" {
				pos += 1
				if let n = peek(), isNameChar(n) || n.value > 0x7F || (n == "\\" && !startsWith("\\\n")) {
					let isIdentifier = isIdentStart(at: pos)
					append(.hash(consumeIdent(), isIdentifier: isIdentifier), at: start)
				} else {
					append(.literal("#"), at: start)
				}
			} else if c == "{" {
				pos += 1
				append(.curlyBrackets(consumeList(endChar: "}")), at: start)
			} else if c == "[" {
				pos += 1
				append(.squareBrackets(consumeList(endChar: "]")), at: start)
			} else if c == "(" {
				pos += 1
				append(.parentheses(consumeList(endChar: ")")), at: start)
			} else if let end = endChar, c == end {
				pos += 1
				return tokens
			} else if c == "}" || c == "]" || c == ")" {
				append(.error(kind: String(c), message: "Unmatched \(c)"), at: start)
				pos += 1
			} else if c == "\"" || c == "'" {
				let result = consumeQuotedString()
				if let value = result.value {
					append(.string(value), at: start)
				}
				if let error = result.error {
					append(.error(kind: error.0, message: error.1), at: start)
				}
			} else if startsWith("/*") {
				pos += 2
				let commentStart = pos
				if let close = find("*/", from: pos) {
					if !skipComments {
						append(.comment(string(from: commentStart, to: close)), at: start)
					}
					pos = close + 2
				} else {
					if !skipComments {
						append(.comment(string(from: commentStart, to: length)), at: start)
					}
					pos = length
				}
			} else if startsWith("<!--") {
				append(.literal("<!--"), at: start)
				pos += 4
			} else if startsWith("||") {
				append(.literal("||"), at: start)
				pos += 2
			} else if c == "~" || c == "|" || c == "^" || c == "$" || c == "*" {
				pos += 1
				if peek() == "=" {
					pos += 1
					append(.literal(String(c) + "="), at: start)
				} else {
					append(.literal(String(c)), at: start)
				}
			} else {
				append(.literal(String(c)), at: start)
				pos += 1
			}
		}
		return tokens
	}

	private func find(_ needle: String, from start: Int) -> Int? {
		let target = Array(needle.unicodeScalars)
		guard !target.isEmpty else { return start }
		var index = start
		while index + target.count <= length {
			var matched = true
			for (offset, scalar) in target.enumerated() where scalars[index + offset] != scalar {
				matched = false
				break
			}
			if matched { return index }
			index += 1
		}
		return nil
	}

	private func nextNonSpaceIsQuote() -> Bool {
		var p = pos
		while p < length, isWhitespace(scalars[p]) { p += 1 }
		guard p < length else { return false }
		return scalars[p] == "\"" || scalars[p] == "'"
	}

	// MARK: - Identifiers and escapes

	private func isIdentStart(at p: Int) -> Bool {
		guard p < length else { return false }
		let c = scalars[p]
		if isNameStart(c) { return true }
		if c == "-" {
			let next = p + 1
			if next < length, isNameStart(scalars[next]) || scalars[next] == "-" { return true }
			return p + 1 < length && scalars[p + 1] == "\\" && !(p + 2 < length && scalars[p + 2] == "\n")
		}
		if c == "\\" {
			return !(p + 1 < length && scalars[p + 1] == "\n")
		}
		return false
	}

	private func consumeIdent() -> String {
		var view = String.UnicodeScalarView()
		while pos < length {
			let c = scalars[pos]
			if isNameChar(c) {
				view.append(c)
				pos += 1
			} else if c == "\\" && !startsWith("\\\n") {
				pos += 1
				view.append(consumeEscape())
			} else {
				break
			}
		}
		return String(view)
	}

	private func consumeEscape() -> Unicode.Scalar {
		// `pos` is just after the backslash.
		if pos < length, isHex(scalars[pos]) {
			var digits = ""
			var count = 0
			while pos < length, count < 6, isHex(scalars[pos]) {
				digits.unicodeScalars.append(scalars[pos])
				pos += 1
				count += 1
			}
			if pos < length, isWhitespace(scalars[pos]) { pos += 1 }
			if let codepoint = UInt32(digits, radix: 16), codepoint > 0,
			   let scalar = Unicode.Scalar(codepoint) {
				return scalar
			}
			return "\u{FFFD}"
		} else if pos < length {
			let c = scalars[pos]
			pos += 1
			return c
		}
		return "\u{FFFD}"
	}

	private func consumeQuotedString() -> (value: String?, error: (String, String)?) {
		let quote = scalars[pos]
		pos += 1
		var view = String.UnicodeScalarView()
		while pos < length {
			let c = scalars[pos]
			if c == quote {
				pos += 1
				return (String(view), nil)
			} else if c == "\\" {
				pos += 1
				if pos < length {
					if scalars[pos] == "\n" {
						pos += 1
					} else {
						view.append(consumeEscape())
					}
				}
			} else if c == "\n" {
				return (nil, ("bad-string", "Bad string token"))
			} else {
				view.append(c)
				pos += 1
			}
		}
		return (String(view), ("eof-in-string", "EOF in string"))
	}

	private func consumeURL() -> (value: String?, error: (String, String)?) {
		while pos < length, isWhitespace(scalars[pos]) { pos += 1 }
		if pos >= length { return ("", ("eof-in-url", "EOF in URL")) }
		let c = scalars[pos]
		var value: String?
		var error: (String, String)?
		if c == "\"" || c == "'" {
			let result = consumeQuotedString()
			value = result.value
			error = result.error
		} else if c == ")" {
			pos += 1
			return ("", nil)
		} else {
			var view = String.UnicodeScalarView()
			loop: while true {
				if pos >= length {
					return (String(view), ("eof-in-url", "EOF in URL"))
				}
				let ch = scalars[pos]
				if ch == ")" {
					pos += 1
					return (String(view), nil)
				} else if isWhitespace(ch) {
					pos += 1
					value = String(view)
					break loop
				} else if ch == "\\" && !startsWith("\\\n") {
					pos += 1
					view.append(consumeEscape())
				} else if ch == "\"" || ch == "'" || ch == "(" || isNonPrintable(ch) {
					value = nil
					pos += 1
					break loop
				} else {
					view.append(ch)
					pos += 1
				}
			}
		}

		if value != nil {
			while pos < length, isWhitespace(scalars[pos]) { pos += 1 }
			if pos < length {
				if scalars[pos] == ")" {
					pos += 1
					return (value, error)
				}
			} else {
				return (value, error ?? ("eof-in-url", "EOF in URL"))
			}
		}

		// Consume the remnants of a bad URL.
		while pos < length {
			if startsWith("\\)") {
				pos += 2
			} else if scalars[pos] == ")" {
				pos += 1
				break
			} else {
				pos += 1
			}
		}
		return (nil, ("bad-url", "bad URL token"))
	}

	private func isNonPrintable(_ s: Unicode.Scalar) -> Bool {
		let v = s.value
		return (v <= 0x08) || v == 0x0B || (v >= 0x0E && v <= 0x1F) || v == 0x7F
	}

	// MARK: - Numbers

	private func consumeNumber() -> (value: Double, int: Int?, representation: String)? {
		var p = pos
		if p < length, scalars[p] == "+" || scalars[p] == "-" { p += 1 }
		let intStart = p
		while p < length, isDigit(scalars[p]) { p += 1 }
		var hasDot = false
		if p < length, scalars[p] == ".", p + 1 < length, isDigit(scalars[p + 1]) {
			p += 1
			while p < length, isDigit(scalars[p]) { p += 1 }
			hasDot = true
		} else if p == intStart {
			return nil // No digits at all.
		}
		var hasExponent = false
		if p < length, scalars[p] == "e" || scalars[p] == "E" {
			var ep = p + 1
			if ep < length, scalars[ep] == "+" || scalars[ep] == "-" { ep += 1 }
			if ep < length, isDigit(scalars[ep]) {
				ep += 1
				while ep < length, isDigit(scalars[ep]) { ep += 1 }
				p = ep
				hasExponent = true
			}
		}
		let representation = string(from: pos, to: p)
		pos = p
		let value = Double(representation) ?? 0
		let int = (!hasDot && !hasExponent) ? Int(representation) : nil
		return (value, int, representation)
	}

	private func consumeUnicodeRange(from start: Int) -> (start: UInt32, end: UInt32) {
		var p = start
		var maxPos = min(p + 6, length)
		let hexStart = p
		while p < maxPos, isHex(scalars[p]) { p += 1 }
		var startHex = string(from: hexStart, to: p)

		let qStart = p
		while p < maxPos, scalars[p] == "?" { p += 1 }
		let questionMarks = p - qStart

		var endHex: String
		if questionMarks > 0 {
			endHex = startHex + String(repeating: "F", count: questionMarks)
			startHex += String(repeating: "0", count: questionMarks)
		} else if p + 1 < length, scalars[p] == "-", isHex(scalars[p + 1]) {
			p += 1
			let secondStart = p
			maxPos = min(p + 6, length)
			while p < maxPos, isHex(scalars[p]) { p += 1 }
			endHex = string(from: secondStart, to: p)
		} else {
			endHex = startHex
		}
		pos = p
		let startValue = UInt32(startHex, radix: 16) ?? 0
		let endValue = UInt32(endHex, radix: 16) ?? 0
		return (startValue, endValue)
	}
}
