//  RenderPDFTests.swift
//  SwiftTextRenderTests

import Testing
import Foundation
@testable import SwiftTextRender
import SwiftTextHTML
import SwiftTextCSS

#if canImport(PDFKit)
import PDFKit
#endif

@Suite("HTML to PDF")
struct RenderPDFTests {

	@Test("Renders a structurally valid PDF with the document's text")
	func rendersValidPDF() async throws {
		let html = """
		<h1>Hello</h1>
		<p>This is a paragraph of text long enough to wrap across several lines \
		when it exceeds the content width of the page.</p>
		"""
		let data = try await HTMLRenderer.renderPDF(html: html)
		#expect(data.starts(with: Data("%PDF".utf8)))

		#if canImport(PDFKit)
		let document = try #require(PDFDocument(data: data))
		#expect(document.pageCount == 1)
		let text = document.string ?? ""
		#expect(text.contains("Hello"))
		#expect(text.contains("paragraph"))
		#endif
	}

	// MARK: - Layout geometry

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

	@Test("Long text wraps onto multiple lines")
	func wrapsLongText() async throws {
		let words = String(repeating: "word ", count: 80)
		let root = try await layoutTree("<p>\(words)</p>", contentWidth: 200)
		let paragraph = try #require(firstBlock(in: root) { $0.element?.localName == "p" })
		#expect(paragraph.lines.count > 1)
		#expect(root.height > 0)
	}

	@Test("Block siblings stack vertically")
	func stacksBlocks() async throws {
		let root = try await layoutTree("<div><p>first</p><p>second</p></div>", contentWidth: 400)
		let div = try #require(firstBlock(in: root) { $0.element?.localName == "div" })
		let paragraphs = div.children.compactMap { $0 as? BlockBox }
		#expect(paragraphs.count == 2)
		#expect(paragraphs[1].y > paragraphs[0].y)
		// The second paragraph starts at or below the bottom of the first.
		#expect(paragraphs[1].y >= paragraphs[0].y + paragraphs[0].height)
	}

	@Test("Box model: padding and border widen the border box")
	func boxModel() async throws {
		let css = ["div { width: 100px; padding: 10px; border: 5px solid black }"]
		let root = try await layoutTree("<div>x</div>", css: css, contentWidth: 400)
		let div = try #require(firstBlock(in: root) { $0.element?.localName == "div" })
		// border-box width = content(100) + padding(2×10) + border(2×5) = 130
		#expect(div.width == 130)
	}

	// MARK: - Sample artifact

	@Test("Generates a sample PDF artifact")
	func generatesSample() async throws {
		let html = """
		<html><body style="font-family: sans-serif; color: #222">
		<h1 style="color:#1a3b5c">SwiftText Render</h1>
		<p>A cross-platform HTML/CSS &rarr; PDF engine — a Swift port of WeasyPrint, \
		with no WebKit. This paragraph is long enough to wrap across multiple lines, \
		demonstrating greedy line breaking using Helvetica metrics.</p>
		<p>It renders <b>bold</b>, <i>italic</i>, and <span style="color:#c0392b">colored</span> \
		inline text, and the full cascade resolves styles from a user-agent stylesheet, \
		author rules, and inline declarations.</p>
		<div style="background-color:#eef2f7; border: 2px solid #1a3b5c; padding: 14px">
		<h3 style="margin-top:0; color:#1a3b5c">The box model</h3>
		<p style="margin-bottom:0">Backgrounds, borders, padding and margins are handled \
		by the block layout engine. Monospace runs use Courier:
		<span style="font-family: monospace">let x = render(html)</span>.</p>
		</div>
		</body></html>
		"""
		let data = try await HTMLRenderer.renderPDF(html: html)
		let url = URL(fileURLWithPath: "/tmp/swifttext_render_sample.pdf")
		try data.write(to: url)
		#expect(data.count > 0)
	}
}
