//  BoxTreeTests.swift
//  SwiftTextRenderTests

import Testing
import Foundation
@testable import SwiftTextRender
import SwiftTextHTML
import SwiftTextCSS

@Suite("Box tree")
struct BoxTreeTests {

	private func boxTree(_ html: String, css: [String] = []) async throws -> Box {
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		let root = try #require(builder.root)
		let resolver = StyleResolver(authorStyleSheets: css)
		let styled = StyledElement.build(domElement: root, resolver: resolver)
		return try #require(BoxTreeBuilder.build(from: styled))
	}

	private func childrenOf(_ box: Box) -> [Box] {
		if let block = box as? BlockBox { return block.children }
		if let inline = box as? InlineBox { return inline.children }
		return []
	}

	private func find(_ box: Box, tag: String) -> Box? {
		if box.element?.localName == tag { return box }
		for child in childrenOf(box) {
			if let found = find(child, tag: tag) { return found }
		}
		return nil
	}

	@Test("A paragraph becomes a block with inline text")
	func paragraph() async throws {
		let tree = try await boxTree("<p>Hello</p>")
		let p = try #require(find(tree, tag: "p") as? BlockBox)
		#expect(p.establishesInlineContext)
		#expect(p.children.count == 1)
		let text = try #require(p.children.first as? TextBox)
		#expect(text.text == "Hello")
	}

	@Test("Mixed block and inline content generates an anonymous block")
	func anonymousBlock() async throws {
		let tree = try await boxTree("<div><p>a</p>b<span>c</span></div>")
		let div = try #require(find(tree, tag: "div") as? BlockBox)
		#expect(div.children.count == 2)

		let first = try #require(div.children[0] as? BlockBox)
		#expect(first.isAnonymous == false)
		#expect(first.element?.localName == "p")

		let anonymous = try #require(div.children[1] as? BlockBox)
		#expect(anonymous.isAnonymous)
		#expect(anonymous.children.count == 2)
		#expect(anonymous.children[0] is TextBox)
		let span = try #require(anonymous.children[1] as? InlineBox)
		#expect(span.element?.localName == "span")
	}

	@Test("display:none produces no box")
	func displayNone() async throws {
		let tree = try await boxTree("<div style=\"display:none\">hidden</div><p>shown</p>")
		#expect(find(tree, tag: "div") == nil)
		#expect(find(tree, tag: "p") != nil)
	}

	@Test("Whitespace between blocks is dropped")
	func whitespaceBetweenBlocks() async throws {
		let tree = try await boxTree("<div>\n  <p>a</p>\n  <p>b</p>\n</div>")
		let div = try #require(find(tree, tag: "div") as? BlockBox)
		#expect(div.children.count == 2)
		#expect(div.children.allSatisfy { ($0 as? BlockBox)?.isAnonymous == false })
	}

	@Test("CSS display:inline turns a div into an inline box")
	func cssDisplayInline() async throws {
		let tree = try await boxTree("<div>x</div>", css: ["div { display: inline }"])
		#expect(find(tree, tag: "div") is InlineBox)
	}
}
