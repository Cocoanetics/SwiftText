//  ListNumberingTests.swift
//  SwiftTextRenderTests

import Testing
import Foundation
@testable import SwiftTextRender
import SwiftTextHTML

/// Ordered-list numbering per the HTML `start` / `reversed` / `value` rules (#133).
extension RenderPDFTests {
	@Test("Ordered list markers honour start, reversed and value", arguments: [
		("<ol start=\"8\"><li>a</li><li>b</li><li>c</li></ol>", ["8.", "9.", "10."]),
		("<ol reversed=\"reversed\"><li>a</li><li>b</li><li>c</li></ol>", ["3.", "2.", "1."]),
		("<ol start=\"5\" reversed=\"reversed\"><li>a</li><li>b</li><li>c</li></ol>", ["5.", "4.", "3."]),
		("<ol><li>a</li><li value=\"20\">b</li><li>c</li></ol>", ["1.", "20.", "21."]),
		("<ol type=\"a\" start=\"3\" style=\"list-style-type: lower-alpha\"><li>a</li></ol>", ["c."]),
		("<ol start=\"3\" style=\"list-style-type: upper-roman\"><li>a</li><li>b</li></ol>", ["III.", "IV."]),
		("<ol start=\"x\"><li>a</li><li>b</li></ol>", ["1.", "2."]),
		("<ol start=\"0\"><li>a</li><li>b</li></ol>", ["0.", "1."])
	])
	func orderedListNumbering(html: String, expected: [String]) async throws {
		let root = try await layoutTree(html, contentWidth: 400)
		let items = collectBlocks(in: root) { $0.element?.localName == "li" }
		#expect(items.map { $0.marker } == expected)
	}

	@Test("Markdown ordered list keeps its start number through layout (#133)")
	func markdownOrderedListStart() async throws {
		let html = MarkdownToHTML.convert("8. acht\n9. neun\n10. zehn")
		let root = try await layoutTree(html, contentWidth: 400)
		let items = collectBlocks(in: root) { $0.element?.localName == "li" }
		#expect(items.map { $0.marker } == ["8.", "9.", "10."])
	}
}
