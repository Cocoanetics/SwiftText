//  BoxModelTests.swift
//  SwiftTextRenderTests

import Foundation
import Testing
@testable import SwiftTextRender
import SwiftTextCSS
import SwiftTextHTML

/// Used-width geometry: how `width`, `min-width`, `max-width`, padding and
/// borders combine into a border box.
@Suite("Box model")
struct BoxModelTests {
	@Test("Padding and border widen the border box")
	func boxModel() async throws {
		let css = ["div { width: 100px; padding: 10px; border: 5px solid black }"]
		let root = try await layoutTree("<div>x</div>", css: css, contentWidth: 400)
		let div = try #require(firstBlock(in: root) { $0.element?.localName == "div" })
		// border-box width = content(100) + padding(2×10) + border(2×5) = 130
		#expect(div.width == 130)
	}

	@Test("min-width raises a narrow box and outranks max-width")
	func minWidthClamp() async throws {
		// A min-width wider than the used width wins.
		let raised = try await layoutTree(
			"<div>x</div>",
			css: ["div { width: 50px; min-width: 200px }"],
			contentWidth: 400)
		#expect(try #require(firstBlock(in: raised) { $0.element?.localName == "div" }).width == 200)

		// When the two conflict, min-width beats max-width (CSS 2.1 §10.4).
		let conflicting = try await layoutTree(
			"<div>x</div>",
			css: ["div { width: 50px; min-width: 300px; max-width: 100px }"],
			contentWidth: 400)
		#expect(try #require(firstBlock(in: conflicting) { $0.element?.localName == "div" }).width == 300)

		// A min-width narrower than the used width changes nothing.
		let unaffected = try await layoutTree(
			"<div>x</div>",
			css: ["div { width: 250px; min-width: 100px }"],
			contentWidth: 400)
		#expect(try #require(firstBlock(in: unaffected) { $0.element?.localName == "div" }).width == 250)
	}

	// MARK: - Helpers

	private func layoutTree(_ html: String, css: [String] = [], contentWidth: Double) async throws -> BlockBox {
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		let root = try #require(builder.root)
		let resolver = StyleResolver(authorStyleSheets: css)
		let styled = StyledElement.build(domElement: root, resolver: resolver)
		let rootBox = try #require(BoxTreeBuilder.build(from: styled) as? BlockBox)
		LayoutEngine(fonts: FontBook()).layout(root: rootBox, contentWidth: contentWidth, originX: 0, originY: 0)
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
