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
#if canImport(AppKit)
import AppKit
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

	@Test("A tall document is paginated across multiple pages")
	func paginatesTallDocument() async throws {
		var html = "<body>"
		for index in 0 ..< 120 {
			html += "<p>Paragraph number \(index): a line of text to fill the page.</p>"
		}
		html += "</body>"
		let data = try await HTMLRenderer.renderPDF(html: html)

		#if canImport(PDFKit)
		let document = try #require(PDFDocument(data: data))
		#expect(document.pageCount > 1)
		// Every page is the same fixed size.
		let firstBounds = document.page(at: 0)?.bounds(for: .mediaBox)
		#expect(firstBounds?.height == 1056 * 0.75)
		#endif
	}

	#if os(macOS)
	@Test("Registered OpenType fonts are embedded (CIDFontType2)")
	func embedsOpenTypeFont() async throws {
		let candidates = [
			"/System/Library/Fonts/Supplemental/Arial.ttf",
			"/System/Library/Fonts/Monaco.ttf",
			"/System/Library/Fonts/Geneva.ttf",
			"/System/Library/Fonts/SFNS.ttf",
		]
		guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
			return // No suitable system font; skip.
		}
		let data = try Data(contentsOf: URL(fileURLWithPath: path))
		let fonts = FontBook()
		try fonts.register(data: data, family: "MyEmbeddedFont")

		let pdf = try await HTMLRenderer.renderPDF(
			html: "<p style=\"font-family: MyEmbeddedFont\">Hello embedded font</p>",
			fonts: fonts)

		func contains(_ marker: String) -> Bool { pdf.range(of: Data(marker.utf8)) != nil }
		#expect(pdf.starts(with: Data("%PDF".utf8)))
		#expect(contains("/Subtype /Type0"))
		#expect(contains("/CIDFontType2"))
		#expect(contains("/Identity-H"))
		#expect(contains("/FontFile2"))

		#if canImport(PDFKit)
		let document = try #require(PDFDocument(data: pdf))
		#expect(document.pageCount >= 1)
		// ToUnicode lets the text be extracted even though it's encoded as glyphs.
		#expect((document.string ?? "").contains("Hello"))
		#endif
	}
	#endif

	// A 1×1 PNG (data URI).
	private let onePixelPNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

	@Test("Decodes image dimensions from a data URI")
	func decodesImageDimensions() {
		let image = ImageDecoder.decode(dataURI: onePixelPNG)
		#expect(image?.width == 1)
		#expect(image?.height == 1)
	}

	@Test("An <img> becomes a replaced box sized by CSS")
	func imageBoxSizing() async throws {
		let root = try await layoutTree("<img src=\"\(onePixelPNG)\" style=\"width:50px;height:30px\">", contentWidth: 400)
		let img = try #require(firstBlock(in: root) { $0.element?.localName == "img" })
		#expect(img.image != nil)
		#expect(img.width == 50)
		#expect(img.height == 30)
	}

	#if canImport(AppKit)
	@Test("A JPEG <img> embeds as a DCTDecode image XObject")
	func embedsJPEGImage() async throws {
		let size = NSSize(width: 8, height: 8)
		let image = NSImage(size: size)
		image.lockFocus()
		NSColor.systemBlue.setFill()
		NSRect(origin: .zero, size: size).fill()
		image.unlockFocus()
		let tiff = try #require(image.tiffRepresentation)
		let bitmap = try #require(NSBitmapImageRep(data: tiff))
		let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
		let uri = "data:image/jpeg;base64," + jpeg.base64EncodedString()

		let pdf = try await HTMLRenderer.renderPDF(html: "<img src=\"\(uri)\">")
		func contains(_ marker: String) -> Bool { pdf.range(of: Data(marker.utf8)) != nil }
		#expect(contains("/Subtype /Image"))
		#expect(contains("/DCTDecode"))
		#expect(contains("/XObject"))

		#if canImport(PDFKit)
		#expect(try #require(PDFDocument(data: pdf)).pageCount >= 1)
		#endif
	}
	#endif

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

	@Test("Adjacent vertical margins collapse")
	func collapsesAdjacentMargins() async throws {
		let root = try await layoutTree("<body><p>a</p><p>b</p></body>", contentWidth: 400)
		let paragraphs = collectBlocks(in: root) { $0.element?.localName == "p" }
		#expect(paragraphs.count == 2)
		// Each <p> has 1em (16px) top and bottom margins; between siblings they
		// collapse to a single 16px gap rather than summing to 32px.
		let gap = paragraphs[1].y - (paragraphs[0].y + paragraphs[0].height)
		#expect(abs(gap - 16) < 0.5)
	}

	@Test("Tables lay cells out in a grid")
	func tableGrid() async throws {
		let html = "<table><tr><td>A</td><td>B</td></tr><tr><td>C</td><td>D</td></tr></table>"
		let root = try await layoutTree(html, contentWidth: 400)
		let cells = collectBlocks(in: root) { $0.element?.localName == "td" }
		#expect(cells.count == 4) // A, B, C, D in document order
		#expect(cells[1].x > cells[0].x)   // B is right of A
		#expect(cells[2].y > cells[0].y)   // C is below A
		#expect(cells[0].y == cells[1].y)  // A and B share a row
		#expect(cells[0].x == cells[2].x)  // A and C share a column
	}

	@Test("Box model: padding and border widen the border box")
	func boxModel() async throws {
		let css = ["div { width: 100px; padding: 10px; border: 5px solid black }"]
		let root = try await layoutTree("<div>x</div>", css: css, contentWidth: 400)
		let div = try #require(firstBlock(in: root) { $0.element?.localName == "div" })
		// border-box width = content(100) + padding(2×10) + border(2×5) = 130
		#expect(div.width == 130)
	}

	private func collectBlocks(in box: BlockBox, where predicate: (BlockBox) -> Bool) -> [BlockBox] {
		var result: [BlockBox] = []
		if predicate(box) { result.append(box) }
		for child in box.children {
			if let block = child as? BlockBox {
				result.append(contentsOf: collectBlocks(in: block, where: predicate))
			}
		}
		return result
	}

	@Test("Unordered and ordered list markers")
	func listMarkers() async throws {
		let unordered = try await layoutTree("<ul><li>apple</li><li>pear</li></ul>", contentWidth: 400)
		let bulletItems = collectBlocks(in: unordered) { $0.element?.localName == "li" }
		#expect(bulletItems.count == 2)
		for item in bulletItems {
			#expect(item.marker == "•")
			let fragments = try #require(item.lines.first?.fragments)
			#expect(fragments.first?.text == "•")
			#expect(fragments.count > 1)
			// The marker sits to the left of the item's text, on the same baseline.
			#expect(fragments[1].x > fragments[0].x)
			#expect(fragments[0].baseline == fragments[1].baseline)
		}

		let ordered = try await layoutTree("<ol><li>one</li><li>two</li><li>three</li></ol>", contentWidth: 400)
		let numberedItems = collectBlocks(in: ordered) { $0.element?.localName == "li" }
		#expect(numberedItems.map { $0.marker } == ["1.", "2.", "3."])
	}

	@Test("<br> forces a line break")
	func forcedLineBreak() async throws {
		let root = try await layoutTree("<p>first line<br>second line</p>", contentWidth: 600)
		let paragraph = try #require(firstBlock(in: root) { $0.element?.localName == "p" })
		#expect(paragraph.lines.count == 2)
	}

	@Test("<pre> preserves newlines")
	func preNewlines() async throws {
		let root = try await layoutTree("<pre>line one\nline two\nline three</pre>", contentWidth: 600)
		let pre = try #require(firstBlock(in: root) { $0.element?.localName == "pre" })
		#expect(pre.lines.count == 3)
	}

	@Test("Links become PDF Link annotations")
	func linkAnnotations() async throws {
		let html = "<p>See <a href=\"https://example.com/\">our site</a> for more.</p>"
		let data = try await HTMLRenderer.renderPDF(html: html)
		let text = String(decoding: data, as: UTF8.self)
		#expect(text.contains("/Subtype /Link"))
		#expect(text.contains("example.com"))

		#if canImport(PDFKit)
		let document = try #require(PDFDocument(data: data))
		let page = try #require(document.page(at: 0))
		let urls = page.annotations.compactMap { ($0.action as? PDFActionURL)?.url?.absoluteString }
		#expect(urls.contains { $0.contains("example.com") })
		#endif
	}

	@Test("text-align: center shifts the line inward")
	func textAlignCenter() async throws {
		let left = try await layoutTree("<p>hi there</p>", contentWidth: 400)
		let center = try await layoutTree("<p style=\"text-align:center\">hi there</p>", contentWidth: 400)
		let leftX = try #require(firstBlock(in: left) { $0.element?.localName == "p" }).lines.first?.fragments.first?.x
		let centerX = try #require(firstBlock(in: center) { $0.element?.localName == "p" }).lines.first?.fragments.first?.x
		#expect(try #require(centerX) > (try #require(leftX)) + 50)
	}

	private func firstStyled(_ element: StyledElement, tag: String) -> StyledElement? {
		if element.localName == tag { return element }
		for child in element.elementChildren {
			if let found = firstStyled(child, tag: tag) { return found }
		}
		return nil
	}

	@Test("Embedded <style> rules are extracted and applied")
	func appliesStyleElement() async throws {
		let html = "<style>p { color: red }</style><p>x</p>"
		let sheets = HTMLRenderer.extractStyleSheets(html: html)
		#expect(sheets.count == 1)

		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		let root = try #require(builder.root)
		let styled = StyledElement.build(domElement: root, resolver: StyleResolver(authorStyleSheets: sheets))
		let paragraph = try #require(firstStyled(styled, tag: "p"))
		#expect(paragraph.computedStyle.color == RGBA(1, 0, 0, 1))
	}

	@Test("Headings produce a PDF outline (bookmarks)")
	func buildsOutline() async throws {
		let html = """
		<h1>Chapter One</h1><p>Intro.</p>
		<h2>Section A</h2><p>Body.</p>
		<h1>Chapter Two</h1><p>More.</p>
		"""
		let data = try await HTMLRenderer.renderPDF(html: html)
		func contains(_ marker: String) -> Bool { data.range(of: Data(marker.utf8)) != nil }
		#expect(contains("/Outlines"))
		#expect(contains("Chapter One"))
		#expect(contains("Section A"))

		#if canImport(PDFKit)
		let document = try #require(PDFDocument(data: data))
		let outline = try #require(document.outlineRoot)
		#expect(outline.numberOfChildren == 2) // two top-level <h1> chapters
		#expect(outline.child(at: 0)?.label == "Chapter One")
		#expect(outline.child(at: 0)?.numberOfChildren == 1) // the nested <h2>
		#endif
	}

	// MARK: - Sample artifact

	@Test("Generates a sample PDF artifact")
	func generatesSample() async throws {
		let html = """
		<html><body style="font-family: sans-serif; color: #222">
		<h1 style="color:#1a3b5c">SwiftText Render</h1>
		<p>A cross-platform HTML/CSS — PDF engine, a Swift port of WeasyPrint, \
		with no WebKit. This paragraph is long enough to wrap across multiple lines, \
		demonstrating greedy line breaking using Helvetica metrics.</p>
		<p>It renders <b>bold</b>, <i>italic</i>, <span style="color:#c0392b">colored</span>, \
		<del>struck-through</del> and <a href="https://github.com/Cocoanetics/SwiftText">linked</a> \
		inline text, all from the full CSS cascade.</p>
		<h3 style="color:#1a3b5c">Features so far</h3>
		<ul>
		<li>Block &amp; inline layout, line breaking, justified text</li>
		<li>Pagination, margins (with collapsing), padding, borders</li>
		<li>Lists, links, embedded OpenType fonts</li>
		</ul>
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
