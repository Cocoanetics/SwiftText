//  CSSTests.swift
//  SwiftTextCSSTests

import Testing
@testable import SwiftTextCSS

@Suite("CSS Tokenizer")
struct CSSTokenizerTests {

	private func tokens(_ css: String) -> [CSSToken] {
		tokenizeComponentValues(css, skipComments: true).map(\.token)
	}

	@Test("Identifiers, colons and whitespace")
	func identifiers() {
		#expect(tokens("color") == [.ident("color")])
		let decl = tokens("color:red")
		#expect(decl == [.ident("color"), .literal(":"), .ident("red")])
	}

	@Test("Numbers, dimensions and percentages")
	func numbers() {
		#expect(tokens("12") == [.number(12, int: 12, representation: "12")])
		#expect(tokens("12.5") == [.number(12.5, int: nil, representation: "12.5")])
		#expect(tokens("1e3") == [.number(1000, int: nil, representation: "1e3")])
		#expect(tokens("12px") == [.dimension(12, int: 12, representation: "12", unit: "px")])
		#expect(tokens("50%") == [.percentage(50, int: 50, representation: "50")])
		#expect(tokens("-0.5em") == [.dimension(-0.5, int: nil, representation: "-0.5", unit: "em")])
	}

	@Test("Hashes, strings and at-keywords")
	func hashesStrings() {
		#expect(tokens("#fff") == [.hash("fff", isIdentifier: true)])
		#expect(tokens("#123") == [.hash("123", isIdentifier: false)])
		#expect(tokens("\"hello\"") == [.string("hello")])
		#expect(tokens("'a b'") == [.string("a b")])
		#expect(tokens("@media") == [.atKeyword("media")])
	}

	@Test("Functions and URLs")
	func functions() {
		let rgb = tokens("rgb(1,2,3)")
		guard case .function(let name, let arguments) = rgb.first else {
			Issue.record("expected function token")
			return
		}
		#expect(name == "rgb")
		#expect(arguments.map(\.token) == [
			.number(1, int: 1, representation: "1"),
			.literal(","),
			.number(2, int: 2, representation: "2"),
			.literal(","),
			.number(3, int: 3, representation: "3")
		])
		#expect(tokens("url(foo.png)") == [.url("foo.png")])
	}

	@Test("Curly blocks nest their content")
	func curlyBlocks() {
		let result = tokenizeComponentValues("{ a }", skipComments: true)
		guard case .curlyBrackets(let content) = result.first?.token else {
			Issue.record("expected curly block")
			return
		}
		#expect(content.contains { $0.identValue == "a" })
	}
}

@Suite("CSS Parser")
struct CSSParserTests {

	private func firstIdent(in values: [ComponentValue]) -> String? {
		values.compactMap(\.identValue).first
	}

	@Test("Parses a style rule into a selector prelude and declarations")
	func styleRule() {
		let nodes = parseStylesheet("p { color: red }", skipComments: true, skipWhitespace: true)
		#expect(nodes.count == 1)
		guard case .qualifiedRule(let rule) = nodes.first else {
			Issue.record("expected qualified rule")
			return
		}
		#expect(firstIdent(in: rule.prelude) == "p")
		let declarations = parseDeclarations(rule.content)
		#expect(declarations.count == 1)
		#expect(declarations.first?.name == "color")
		#expect(firstIdent(in: declarations.first?.value ?? []) == "red")
	}

	@Test("Parses inline-style declarations with !important")
	func inlineDeclarations() {
		let declarations = parseDeclarations(inlineStyle: "color: blue; font-size: 12px !important")
		#expect(declarations.count == 2)
		#expect(declarations[0].name == "color")
		#expect(declarations[0].important == false)

		let fontSize = declarations[1]
		#expect(fontSize.name == "font-size")
		#expect(fontSize.important == true)
		// The "!important" marker is stripped from the stored value.
		#expect(fontSize.value.contains { $0.isLiteral("!") } == false)
		#expect(fontSize.value.contains {
			if case .dimension(_, _, _, let unit) = $0.token { return unit == "px" }
			return false
		})
	}

	@Test("Parses at-rules with a block")
	func atRule() {
		let nodes = parseStylesheet("@media print { p { color: red } }", skipComments: true, skipWhitespace: true)
		#expect(nodes.count == 1)
		guard case .atRule(let rule) = nodes.first else {
			Issue.record("expected at-rule")
			return
		}
		#expect(rule.lowerAtKeyword == "media")
		#expect(rule.content != nil)
		#expect(firstIdent(in: rule.prelude) == "print")
	}

	@Test("Parses a single declaration")
	func oneDeclaration() {
		guard case .declaration(let declaration) = parseOneDeclaration("margin: 0 auto") else {
			Issue.record("expected declaration")
			return
		}
		#expect(declaration.name == "margin")
	}

	@Test("Case-insensitive declaration names are lowercased")
	func lowercasing() {
		let declarations = parseDeclarations(inlineStyle: "COLOR: RED")
		#expect(declarations.first?.lowerName == "color")
		#expect(declarations.first?.name == "COLOR")
	}
}
