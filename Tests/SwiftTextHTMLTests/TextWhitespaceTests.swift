//  TextWhitespaceTests.swift
//  SwiftTextHTMLTests

import Foundation
import Testing
@testable import SwiftTextHTML

/// Plain-text extraction reassembles the text nodes itself, so it decides what
/// each run of whitespace between them meant: a word separator where text meets
/// across it, and nothing at all against a block boundary.
@Suite("Text whitespace")
struct TextWhitespaceTests {
	@Test("Whitespace ending a text node still separates words", arguments: [
		("<p>Wort A\n<strong>fett</strong> danach.</p>", "Wort A fett danach."),
		("<p>Wort B\n<code>code</code> danach.</p>", "Wort B code danach."),
		("<p>Wort C\n<em>kursiv</em> danach.</p>", "Wort C kursiv danach."),
		("<p>Wort D\n<a href=\"https://example.org\">link</a> danach.</p>", "Wort D link danach."),
		("<p>Text mit <strong>fett</strong>\nund Fortsetzung.</p>", "Text mit fett und Fortsetzung."),
		("<p>Tab\t<em>kursiv</em> danach.</p>", "Tab kursiv danach.")
	])
	func whitespaceEndingATextNode(_ testCase: (html: String, expected: String)) async throws {
		#expect(try await text(testCase.html) == testCase.expected)
	}

	@Test("Whitespace between inline siblings separates them", arguments: [
		"div", "blockquote", "section", "p", "li", "span"
	])
	func whitespaceBetweenInlineSiblings(_ container: String) async throws {
		let html = "<\(container)><a href=\"/a\">Impressum</a>\n<strong>AGB</strong></\(container)>"
		#expect(try await text(html) == "Impressum AGB")
	}

	@Test("Whitespace between block siblings separates nothing", arguments: [
		"div", "section", "article", "main", "header", "aside", "dl", "blockquote"
	])
	func whitespaceBetweenBlockSiblings(_ container: String) async throws {
		let html = "<\(container)>\n  <p>Erster</p>\n  <p>Zweiter</p>\n</\(container)>"
		#expect(try await text(html) == "Erster\n\nZweiter")
	}

	@Test("A block's own edges hold no separator")
	func blockEdgesHoldNoSeparator() async throws {
		#expect(try await text("<p>\n  Wort A <strong>fett</strong>\n</p>") == "Wort A fett")
	}

	@Test("Whitespace inside an inline wrapper separates surrounding words")
	func inlineWrapperWhitespaceSeparatesWords() async throws {
		#expect(try await text("<p>Hello<span> </span>world</p>") == "Hello world")
	}

	@Test("Collapsed whitespace is coalesced across inline boundaries", arguments: [
		"<p>Hello <span> world</span></p>",
		"<p>Hello <span><span> </span> world</span></p>"
	])
	func boundaryWhitespaceCollapsesOnce(_ html: String) async throws {
		#expect(try await text(html) == "Hello world")
	}

	@Test("A <br> is a boundary, not a separator")
	func lineBreakIsABoundary() async throws {
		#expect(try await text("<p>Wort A<br>\n<strong>fett</strong></p>") == "Wort A\nfett")
	}

	@Test("A <pre> keeps its indentation, even nested in a block")
	func preKeepsIndentation() async throws {
		let html = "<div>\n  <p>Vor</p>\n  <pre><code>f() {\n    return 1\n}</code></pre>\n</div>"
		#expect(try await text(html) == "Vor\n\nf() {\n    return 1\n}")
	}

	private func text(_ html: String) async throws -> String {
		try await HTMLDocument(data: Data(html.utf8), baseURL: nil).text()
	}
}
