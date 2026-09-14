//  TextDecorationTests.swift
//  SwiftTextRenderTests

import Foundation
import Testing
@testable import SwiftTextRender
import SwiftTextCSS
import SwiftTextHTML

@Suite("Text decoration")
struct TextDecorationTests {
	@Test("Text decorations span whitespace within an inline run", arguments: [
		"<p><a href=\"https://example.com\">Ein Link aus mehreren Woertern</a></p>",
		"<p><s>Ein durchgestrichener Satz aus mehreren Woertern</s></p>"
	])
	func textDecorationsSpanWhitespace(_ html: String) async throws {
		let data = try await HTMLRenderer.renderPDF(
			html: html,
			options: RenderOptions(compressStreams: false))
		// One rectangle clips the page content; the other is the single
		// decoration bar spanning every word and intervening space.
		#expect(rectangleCount(in: data) == 2)
	}

	@Test("Wrapped text decorations produce one bar per line")
	func wrappedTextDecorationsProduceOneBarPerLine() async throws {
		let html = "<p><u>one two three four five six seven eight nine ten</u></p>"
		let contentWidth = 120.0
		let root = try await layoutTree(html, contentWidth: contentWidth)
		let paragraph = try #require(firstBlock(in: root) { $0.element?.localName == "p" })
		#expect(paragraph.lines.count > 1)

		let data = try await HTMLRenderer.renderPDF(
			html: html,
			options: RenderOptions(pageWidthPx: contentWidth + 64, pageHeightPx: nil,
			                       pageMarginPx: 32, compressStreams: false))
		#expect(rectangleCount(in: data) - 1 == paragraph.lines.count)
	}

	@Test("Separate decorated elements keep separate bars")
	func separateDecoratedElementsKeepSeparateBars() async throws {
		let data = try await HTMLRenderer.renderPDF(
			html: "<p><u>one</u> <u>two</u></p>",
			options: RenderOptions(compressStreams: false))
		#expect(rectangleCount(in: data) == 3)
	}

	private func rectangleCount(in data: Data) -> Int {
		String(decoding: data, as: UTF8.self)
			.split(separator: "\n")
			.filter { $0.hasSuffix(" re") }
			.count
	}

	private func layoutTree(_ html: String, contentWidth: Double) async throws -> BlockBox {
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		let root = try #require(builder.root)
		let styled = StyledElement.build(domElement: root, resolver: StyleResolver())
		let rootBox = try #require(BoxTreeBuilder.build(from: styled) as? BlockBox)
		LayoutEngine(fonts: FontBook()).layout(
			root: rootBox, contentWidth: contentWidth, originX: 0, originY: 0)
		return rootBox
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
