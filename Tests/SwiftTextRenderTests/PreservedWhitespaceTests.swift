//  PreservedWhitespaceTests.swift
//  SwiftTextRenderTests

import Foundation
import Testing
@testable import SwiftTextRender
import SwiftTextCSS
import SwiftTextHTML

/// `pre` and `pre-wrap` preserve every space they are given; `pre-line` and
/// `normal` collapse runs of them. The two preserving modes differ only in
/// whether a long line may wrap — which is why `pre-wrap` is what the Markdown
/// stylesheet gives a fenced code block, and why its spaces carry the block's
/// indentation.
@Suite("Preserved whitespace")
struct PreservedWhitespaceTests {
	@Test("A preserving white-space mode keeps runs of spaces", arguments: ["pre", "pre-wrap"])
	func preservingModesKeepSpaceRuns(_ mode: String) async throws {
		let lines = try await lineTexts("<p style=\"white-space: \(mode)\">A\nB  C</p>")
		#expect(lines == ["A", "B  C"])
	}

	@Test("A preserving white-space mode keeps leading indentation", arguments: ["pre", "pre-wrap"])
	func preservingModesKeepIndentation(_ mode: String) async throws {
		let lines = try await lineTexts("<p style=\"white-space: \(mode)\">f() {\n    return 1\n}</p>")
		#expect(lines == ["f() {", "    return 1", "}"])
	}

	/// A collapsed separator is a gap the line builder opens between fragments,
	/// not a space any fragment carries, so it shows here as `·`.
	@Test("A collapsing white-space mode collapses runs of spaces", arguments: [
		("pre-line", ["A", "B·C"]),
		("normal", ["A·B·C"]),
		("nowrap", ["A·B·C"])
	])
	func collapsingModesCollapseSpaceRuns(_ testCase: (mode: String, expected: [String])) async throws {
		let lines = try await lineTexts("<p style=\"white-space: \(testCase.mode)\">A\nB  C</p>")
		#expect(lines == testCase.expected)
	}

	/// The fenced-code-block shape the Markdown stylesheet produces.
	@Test("A pre-wrap code block keeps its indentation")
	func preWrapCodeBlockKeepsIndentation() async throws {
		let html = """
			<style>pre, pre code { white-space: pre-wrap; }</style>
			<pre><code>func f() {
			    if x {
			        return 1
			    }
			}</code></pre>
			"""
		#expect(try await lineTexts(html, blockName: "pre") == [
			"func f() {", "    if x {", "        return 1", "    }", "}"
		])
	}

	@Test("pre-wrap still wraps a line too long for the block")
	func preWrapStillWraps() async throws {
		let html = "<p style=\"white-space: pre-wrap\">aaa bbb ccc ddd eee fff ggg hhh</p>"
		#expect(try await lineTexts(html, contentWidth: 60).count > 1)
	}

	// MARK: - Helpers

	/// Each line's text with the spaces its fragments carry, and a gap the line
	/// builder opened between two fragments shown as `·`.
	private func lineTexts(
		_ html: String, blockName: String = "p", contentWidth: Double = 600
	) async throws -> [String] {
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		let root = try #require(builder.root)
		let styled = StyledElement.build(
			domElement: root,
			resolver: StyleResolver(authorStyleSheets: root.styleSheets()))
		let rootBox = try #require(BoxTreeBuilder.build(from: styled) as? BlockBox)
		LayoutEngine(fonts: FontBook()).layout(
			root: rootBox, contentWidth: contentWidth, originX: 0, originY: 0)
		let block = try #require(firstBlock(in: rootBox) { $0.element?.localName == blockName })
		return block.lines.map { line in
			var text = ""
			var previousEnd: Double?
			for fragment in line.fragments {
				if let previousEnd, fragment.x - previousEnd > 0.5 { text += "·" }
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
