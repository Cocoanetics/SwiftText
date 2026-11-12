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

	// MARK: - Blocks inside inline boxes (CSS 2.1 §9.2.1.1)

	@Test("An inline box holding a block is split around it, the block becoming a sibling")
	func blockInInlineSplits() async throws {
		let tree = try await boxTree("<section><a href=\"#\">before<div>block</div>after</a></section>")
		let section = try #require(find(tree, tag: "section") as? BlockBox)
		try #require(section.children.count == 3)

		let block = try #require(section.children[1] as? BlockBox)
		#expect(block.element?.localName == "div")
		#expect((block.children.first as? TextBox)?.text == "block")

		// The text either side stays in pieces of the link, each in an anonymous block.
		for (index, text) in [(0, "before"), (2, "after")] {
			let anonymous = try #require(section.children[index] as? BlockBox)
			#expect(anonymous.isAnonymous)
			let piece = try #require(anonymous.children.first as? InlineBox)
			#expect(piece.element?.localName == "a")
			#expect((piece.children.first as? TextBox)?.text == text)
		}
	}

	@Test("A block nested in several inline boxes comes out of all of them")
	func blockInNestedInlines() async throws {
		let tree = try await boxTree("<section><a href=\"#\"><span>x<p>para</p></span></a></section>")
		let section = try #require(find(tree, tag: "section") as? BlockBox)
		#expect(section.children.compactMap { ($0 as? BlockBox)?.element?.localName } == ["p"])
		#expect(find(section, tag: "span") is InlineBox)
	}

	@Test("Whitespace around a block in an inline box leaves no empty pieces")
	func blockInInlineDropsWhitespacePieces() async throws {
		let tree = try await boxTree("<section><a href=\"#\">\n  <img src=\"x.png\" style=\"display: block\">\n</a></section>")
		let section = try #require(find(tree, tag: "section") as? BlockBox)
		#expect(section.children.count == 1)
		#expect((section.children.first as? BlockBox)?.element?.localName == "img")
	}

	@Test("An inline box with an id keeps a piece before its block, for internal links")
	func blockInAnchorKeepsTarget() async throws {
		let tree = try await boxTree("<section><a id=\"target\"><div>block</div></a></section>")
		let section = try #require(find(tree, tag: "section") as? BlockBox)
		try #require(section.children.count == 2)
		let anonymous = try #require(section.children.first as? BlockBox)
		#expect(anonymous.isAnonymous)
		let piece = try #require(anonymous.children.first as? InlineBox)
		#expect(piece.element?.attributeValue("id") == "target")
		#expect((section.children[1] as? BlockBox)?.element?.localName == "div")
	}

	@Test("A block split out of a link keeps the link, down to the blocks inside it")
	func blockInLinkKeepsHref() async throws {
		let tree = try await boxTree("<section><a href=\"https://example.com/book\"><div><p>Title</p></div></a></section>")
		let div = try #require(find(tree, tag: "div") as? BlockBox)
		#expect(div.linkHref == "https://example.com/book")
		let p = try #require(find(div, tag: "p") as? BlockBox)
		#expect(p.linkHref == "https://example.com/book")
	}

	@Test("A block-level link hands its href to its blocks; other blocks have none")
	func blockLevelLinkHref() async throws {
		let tree = try await boxTree("<a href=\"https://example.com/\" style=\"display: block\"><p>Go</p></a><p>Plain</p>")
		let link = try #require(find(tree, tag: "a") as? BlockBox)
		#expect(link.linkHref == "https://example.com/")
		#expect((link.children.first as? BlockBox)?.linkHref == "https://example.com/")
		let body = try #require(find(tree, tag: "body") as? BlockBox)
		let plain = try #require(body.children.last as? BlockBox)
		#expect(plain.element?.localName == "p")
		#expect(plain.linkHref == nil)
	}

	@Test("An inline-block that holds blocks lays out as a block")
	func inlineBlockWithBlocks() async throws {
		let tree = try await boxTree("<div><span style=\"display: inline-block\"><p>Bibliothek</p></span></div>")
		let span = try #require(find(tree, tag: "span") as? BlockBox)
		#expect(span.style.display == .block)
		#expect((span.children.first as? BlockBox)?.element?.localName == "p")
	}

	@Test("An inline-block of inline content stays an inline box")
	func inlineBlockWithInlines() async throws {
		let tree = try await boxTree("<p><a href=\"#\" style=\"display: inline-block\">Button</a></p>")
		#expect(find(tree, tag: "a") is InlineBox)
	}

	// MARK: - Anonymous table cells (CSS 2.1 §17.2.1)

	@Test("A table row's non-cell children are wrapped in one anonymous cell")
	func nonCellRowChildrenGetACell() async throws {
		let html = """
			<table><tr><td>a</td><td style="display: block">b</td><td style="display: block">c</td><td>d</td></tr></table>
			"""
		let tree = try await boxTree(html)
		let row = try #require(find(tree, tag: "tr") as? BlockBox)
		try #require(row.children.count == 3)
		#expect(row.children.allSatisfy { ($0 as? BlockBox)?.style.display == .tableCell })

		let anonymous = try #require(row.children[1] as? BlockBox)
		#expect(anonymous.isAnonymous)
		let wrapped = anonymous.children.compactMap { $0 as? BlockBox }
		#expect(wrapped.count == 2)
		#expect(wrapped.allSatisfy { $0.element?.localName == "td" && $0.style.display == .block })
	}

	@Test("A row of cells gets no anonymous cell")
	func cellRowUnchanged() async throws {
		let tree = try await boxTree("<table><tr>\n<td>a</td>\n<td>b</td>\n</tr></table>")
		let row = try #require(find(tree, tag: "tr") as? BlockBox)
		#expect(row.children.count == 2)
		#expect(row.children.allSatisfy { ($0 as? BlockBox)?.isAnonymous == false })
	}
}
