//  InlineWhitespaceTests.swift
//  SwiftTextRenderTests

import Foundation
import Testing
@testable import SwiftTextRender
import SwiftTextCSS
import SwiftTextHTML

/// A Markdown soft break becomes a bare newline in the HTML the renderer lays
/// out. Whether it sits next to plain text or next to an inline element, it must
/// assemble into exactly one inter-word space on the line.
@Suite("Inline whitespace")
struct InlineWhitespaceTests {
	@Test("A soft break before an inline element contributes a space", arguments: [
		("strong", "<p>Wort A\n<strong>fett</strong> danach.</p>", "Wort A fett danach."),
		("code", "<p>Wort B\n<code>code</code> danach.</p>", "Wort B code danach."),
		("em", "<p>Wort C\n<em>kursiv</em> danach.</p>", "Wort C kursiv danach."),
		("a", "<p>Wort D\n<a href=\"https://example.org\">link</a> danach.</p>", "Wort D link danach.")
	])
	func softBreakBeforeInlineElement(_ testCase: (name: String, html: String, expected: String)) async throws {
		#expect(try await singleLineText(testCase.html) == testCase.expected)
	}

	@Test("A soft break after an inline element contributes a space", arguments: [
		("strong", "<p>Text mit <strong>fett</strong>\nund Fortsetzung.</p>", "Text mit fett und Fortsetzung."),
		("code", "<p>Text mit <code>code</code>\nund Fortsetzung.</p>", "Text mit code und Fortsetzung."),
		("em", "<p>Text mit <em>kursiv</em>\nund Fortsetzung.</p>", "Text mit kursiv und Fortsetzung."),
		("a", "<p>Text mit <a href=\"https://example.org\">link</a>\nund Fortsetzung.</p>",
		 "Text mit link und Fortsetzung.")
	])
	func softBreakAfterInlineElement(_ testCase: (name: String, html: String, expected: String)) async throws {
		#expect(try await singleLineText(testCase.html) == testCase.expected)
	}

	@Test("A soft break between two plain-text runs contributes a space")
	func softBreakBetweenPlainText() async throws {
		#expect(try await singleLineText("<p>Eins\nzwei drei.</p>") == "Eins zwei drei.")
	}

	@Test("Whitespace before the newline does not double the space", arguments: [
		"<p>Wort A \n<strong>fett</strong></p>",
		"<p>Wort A\n <strong>fett</strong></p>",
		"<p>Wort A \n\t <strong>fett</strong></p>",
		"<p>Wort A\n<strong> fett</strong></p>"
	])
	func collapsedWhitespaceAroundSoftBreak(_ html: String) async throws {
		#expect(try await singleLineText(html) == "Wort A fett")
	}

	@Test("Leading and trailing whitespace around a line is dropped")
	func edgeWhitespaceIsDropped() async throws {
		#expect(try await singleLineText("<p>\n  Wort A <strong>fett</strong>\n</p>") == "Wort A fett")
	}

	/// A hard break (Markdown's two trailing spaces, or a trailing backslash)
	/// becomes `<br>`: it must still break the line, and must not leave a
	/// leading space on the next one.
	@Test("A hard break stays a break next to an inline element", arguments: [
		"<p>Wort A<br>\n<strong>fett</strong></p>",
		"<p>Wort A <br>\n<strong>fett</strong></p>",
		"<p>Wort A<br>\n  <strong>fett</strong></p>"
	])
	func hardBreakNextToInlineElement(_ html: String) async throws {
		#expect(try await lineTexts(html) == ["Wort A", "fett"])
	}

	@Test("A hard break after an inline element stays a break")
	func hardBreakAfterInlineElement() async throws {
		#expect(try await lineTexts("<p>Text mit <strong>fett</strong><br>\nund Fortsetzung.</p>")
			== ["Text mit fett", "und Fortsetzung."])
	}

	// MARK: - Helpers

	private func singleLineText(_ html: String) async throws -> String {
		let texts = try await lineTexts(html)
		#expect(texts.count == 1)
		return texts.first ?? ""
	}

	/// The visible text of each line of the first `<p>`, with an inter-fragment
	/// gap reported as the space it paints as.
	private func lineTexts(_ html: String) async throws -> [String] {
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		let root = try #require(builder.root)
		let styled = StyledElement.build(domElement: root, resolver: StyleResolver())
		let rootBox = try #require(BoxTreeBuilder.build(from: styled) as? BlockBox)
		LayoutEngine(fonts: FontBook()).layout(
			root: rootBox, contentWidth: 600, originX: 0, originY: 0)
		let paragraph = try #require(firstBlock(in: rootBox) { $0.element?.localName == "p" })
		return paragraph.lines.map { line in
			var text = ""
			var previousEnd: Double?
			for fragment in line.fragments {
				if let previousEnd, fragment.x - previousEnd > 0.5 { text += " " }
				text += fragment.text
				previousEnd = fragment.x + fragment.width
			}
			return text
		}
	}

	private func firstBlock(in box: BlockBox, where predicate: (BlockBox) -> Bool) -> BlockBox? {
		if predicate(box) { return box }
		for child in box.children {
			if let block = child as? BlockBox, let found = firstBlock(in: block, where: predicate) {
				return found
			}
		}
		return nil
	}
}
