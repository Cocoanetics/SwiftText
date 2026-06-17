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

	@Test("The default serif family resolves to Times-Roman")
	func serifIsTimes() {
		guard case .standard(let font) = FontBook().font(for: ComputedStyle.initial) else {
			Issue.record("expected a standard font")
			return
		}
		#expect(font.baseFontName == "Times-Roman") // CSS default font-family is serif
	}

	@Test("Bold text uses wider Helvetica-Bold metrics")
	func boldMetrics() {
		let fonts = FontBook()
		let regular = ComputedStyle.initial
		var bold = ComputedStyle.initial
		bold.fontWeight = 700
		#expect(fonts.font(for: bold).width(of: "Modules", size: 16) > fonts.font(for: regular).width(of: "Modules", size: 16))
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

	@Test("Table cells honor colspan")
	func tableColspan() async throws {
		let html = "<table><tr><td colspan=2>Wide</td></tr><tr><td>A</td><td>B</td></tr></table>"
		let root = try await layoutTree(html, contentWidth: 400)
		let cells = collectBlocks(in: root) { $0.element?.localName == "td" } // Wide, A, B
		#expect(cells.count == 3)
		#expect(cells[0].width > cells[1].width * 1.5) // spans ~2 columns
		#expect(abs(cells[0].x - cells[1].x) < 0.01)     // starts at column 0
		#expect(cells[2].x > cells[1].x)                 // B right of A
	}

	@Test("Table cells honor rowspan")
	func tableRowspan() async throws {
		let html = "<table><tr><td rowspan=2>Tall</td><td>A</td></tr><tr><td>B</td></tr></table>"
		let root = try await layoutTree(html, contentWidth: 400)
		let cells = collectBlocks(in: root) { $0.element?.localName == "td" } // Tall, A, B
		#expect(cells.count == 3)
		#expect(abs(cells[2].x - cells[1].x) < 0.01) // B shares A's column
		#expect(cells[2].y > cells[1].y)              // B is below A
		#expect(cells[0].height >= cells[1].height + cells[2].height) // Tall spans both rows
	}

	@Test("Table cell vertical-align: bottom pushes content down")
	func cellVerticalAlign() async throws {
		let html = "<table><tr><td style=\"height:100px\">tall</td><td style=\"vertical-align: bottom\">low</td></tr></table>"
		let root = try await layoutTree(html, contentWidth: 400)
		let cells = collectBlocks(in: root) { $0.element?.localName == "td" }
		#expect(cells.count == 2)
		let low = cells[1]
		#expect(abs(cells[0].height - low.height) < 0.5) // both fill the row
		let baseline = try #require(low.lines.first?.fragments.first?.baseline)
		#expect(baseline > low.y + low.height / 2) // content sits in the lower half
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

	@Test("<pre> preserves runs of spaces")
	func prePreservesSpaces() async throws {
		let preRoot = try await layoutTree("<pre>a     b</pre>", contentWidth: 600)
		let pre = try #require(firstBlock(in: preRoot) { $0.element?.localName == "pre" })
		// The whole "a     b" (with its five spaces) is one preserved fragment.
		let fragment = try #require(pre.lines.first?.fragments.first)
		#expect(fragment.text == "a     b")
		// It is much wider than the collapsed "a b" would be.
		let collapsedRoot = try await layoutTree("<pre>a b</pre>", contentWidth: 600)
		let collapsed = try #require(firstBlock(in: collapsedRoot) { $0.element?.localName == "pre" })
		#expect(fragment.width > (collapsed.lines.first?.fragments.first?.width ?? 0) * 1.5)
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

	@Test("letter-spacing widens text and emits Tc")
	func letterSpacing() async throws {
		let plain = try await layoutTree("<p>hello</p>", contentWidth: 600)
		let spaced = try await layoutTree("<p style=\"letter-spacing:5px\">hello</p>", contentWidth: 600)
		let plainBlock = try #require(firstBlock(in: plain) { $0.element?.localName == "p" })
		let spacedBlock = try #require(firstBlock(in: spaced) { $0.element?.localName == "p" })
		let plainWidth = try #require(plainBlock.lines.first?.fragments.first?.width)
		let spacedWidth = try #require(spacedBlock.lines.first?.fragments.first?.width)
		#expect(abs((spacedWidth - plainWidth) - 25) < 0.5) // "hello" is 5 chars × 5px

		let data = try await HTMLRenderer.renderPDF(html: "<p style=\"letter-spacing:2px\">hi</p>")
		#expect(data.range(of: Data(" Tc".utf8)) != nil)
	}

	@Test("list-style-type: alpha, roman, square and none")
	func listStyleTypes() async throws {
		let alpha = try await layoutTree("<ol style=\"list-style-type: lower-alpha\"><li>x</li><li>y</li><li>z</li></ol>", contentWidth: 400)
		#expect(collectBlocks(in: alpha) { $0.element?.localName == "li" }.map { $0.marker } == ["a.", "b.", "c."])

		let roman = try await layoutTree("<ol style=\"list-style-type: upper-roman\"><li>a</li><li>b</li><li>c</li><li>d</li></ol>", contentWidth: 400)
		#expect(collectBlocks(in: roman) { $0.element?.localName == "li" }.map { $0.marker } == ["I.", "II.", "III.", "IV."])

		let square = try await layoutTree("<ul style=\"list-style-type: square\"><li>x</li></ul>", contentWidth: 400)
		#expect(collectBlocks(in: square) { $0.element?.localName == "li" }.first?.marker == "▪")

		let plain = try await layoutTree("<ul style=\"list-style-type: none\"><li>x</li></ul>", contentWidth: 400)
		#expect(collectBlocks(in: plain) { $0.element?.localName == "li" }.first?.marker == nil)

		// arabic-indic: decimal counters rendered with Arabic-Indic digits ٠١٢…
		let arabic = try await layoutTree("<ol style=\"list-style-type: arabic-indic\"><li>x</li><li>y</li><li>z</li></ol>", contentWidth: 400)
		#expect(collectBlocks(in: arabic) { $0.element?.localName == "li" }.map { $0.marker } == ["\u{0661}.", "\u{0662}.", "\u{0663}."])
	}

	@Test("RTL list markers sit to the right of the item, in the inline-start padding")
	func rtlListMarkers() async throws {
		// LTR: padding-inline-start is the left, marker to the left of the text.
		let ltr = try await layoutTree("<ol><li>x</li></ol>", contentWidth: 400)
		let ltrItems = collectBlocks(in: ltr) { $0.element?.localName == "li" }
		let ltrItem = try #require(ltrItems.first)
		let ltrFragments = try #require(ltrItem.lines.first?.fragments)
		#expect(ltrFragments.first?.text == "1.")                                   // marker first
		#expect((ltrFragments.first?.x ?? 0) < (ltrFragments.dropFirst().first?.x ?? 0)) // marker on the left

		// RTL: padding-inline-start is the right, marker to the right of the text.
		let rtl = try await layoutTree("<ol dir=\"rtl\" style=\"list-style-type: arabic-indic\"><li>\u{0623}</li></ol>", contentWidth: 400)
		let rtlItems = collectBlocks(in: rtl) { $0.element?.localName == "li" }
		let rtlItem = try #require(rtlItems.first)
		let rtlFragments = try #require(rtlItem.lines.first?.fragments)
		let marker = try #require(rtlFragments.first)
		#expect(marker.text == "\u{0661}.")                                          // ١.
		let maxTextX = rtlFragments.dropFirst().map { $0.x }.max() ?? 0
		#expect(marker.x > maxTextX)                                                 // marker on the right
		// The marker lives in the list's inline-start (right, for RTL) padding —
		// outside the item box but contained within the <ol>'s border box.
		let lists = collectBlocks(in: rtl) { $0.element?.localName == "ol" }
		let list = try #require(lists.first)
		#expect(marker.x > rtlItem.x + rtlItem.width - 0.5)                          // beyond the item's right edge
		#expect(marker.x + marker.width <= list.x + list.width + 0.5)               // within the list padding
	}

	@Test("text-indent indents only the first line")
	func textIndent() async throws {
		let text = "Hello world this is a longer paragraph that wraps onto several lines here"
		let plain = try await layoutTree("<p>\(text)</p>", contentWidth: 150)
		let indented = try await layoutTree("<p style=\"text-indent: 30px\">\(text)</p>", contentWidth: 150)
		let plainBlock = try #require(firstBlock(in: plain) { $0.element?.localName == "p" })
		let indentedBlock = try #require(firstBlock(in: indented) { $0.element?.localName == "p" })
		#expect(plainBlock.lines.count >= 2)

		let plainFirst = try #require(plainBlock.lines.first?.fragments.first?.x)
		let indentedFirst = try #require(indentedBlock.lines.first?.fragments.first?.x)
		#expect(abs((indentedFirst - plainFirst) - 30) < 0.5)

		// The second line is not indented.
		let plainSecond = try #require(plainBlock.lines.dropFirst().first?.fragments.first?.x)
		let indentedSecond = try #require(indentedBlock.lines.dropFirst().first?.fragments.first?.x)
		#expect(abs(indentedSecond - plainSecond) < 0.5)
	}

	@Test("An RTL (Hebrew) paragraph is reordered and right-aligned")
	func rtlParagraph() async throws {
		// "אב גד" with dir=rtl → visually: גד(=דג) on the left, אב(=בא) on the right.
		let html = "<p dir=\"rtl\">\u{05D0}\u{05D1} \u{05D2}\u{05D3}</p>"
		let root = try await layoutTree(html, contentWidth: 300)
		let p = try #require(firstBlock(in: root) { $0.element?.localName == "p" })
		let fragments = try #require(p.lines.first?.fragments)
		#expect(fragments.count == 2)
		#expect(fragments[0].text == "\u{05D3}\u{05D2}") // second word, reversed
		#expect(fragments[1].text == "\u{05D1}\u{05D0}") // first word, reversed
		#expect(fragments[0].x < fragments[1].x)          // visual left-to-right
		// Right-aligned: the line's right edge meets the content's right edge.
		#expect(fragments[1].x + fragments[1].width > p.x + p.width - 5)
	}

	@Test("Base direction propagates to content without a dir attribute")
	func baseDirectionPropagates() async throws {
		// No dir attribute anywhere; the document base direction makes it RTL —
		// this is what auto-detection gives a Hebrew Markdown file.
		let builder = try await DomBuilder(html: Data("<p>\u{05D0}\u{05D1} \u{05D2}\u{05D3}</p>".utf8), baseURL: nil)
		let root = try #require(builder.root)
		let styled = StyledElement.build(domElement: root, resolver: StyleResolver(), baseDirection: .rtl)
		let rootBox = try #require(BoxTreeBuilder.build(from: styled) as? BlockBox)
		LayoutEngine(fonts: FontBook()).layout(root: rootBox, contentWidth: 300, originX: 0, originY: 0)
		let p = try #require(firstBlock(in: rootBox) { $0.element?.localName == "p" })
		let fragments = try #require(p.lines.first?.fragments)
		#expect(fragments[0].text == "\u{05D3}\u{05D2}") // reordered + reversed, despite no dir attr
		#expect(fragments[0].x < fragments[1].x)
	}

	@Test("A Hebrew run inside an LTR paragraph flips but stays after the Latin")
	func hebrewInLTRParagraph() async throws {
		let html = "<p>Hello \u{05D0}\u{05D1}\u{05D2}</p>" // "Hello אבג"
		let root = try await layoutTree(html, contentWidth: 400)
		let p = try #require(firstBlock(in: root) { $0.element?.localName == "p" })
		let fragments = try #require(p.lines.first?.fragments)
		#expect(fragments.count == 2)
		#expect(fragments[0].text == "Hello")
		#expect(fragments[1].text == "\u{05D2}\u{05D1}\u{05D0}") // אבג reversed → גבא
		#expect(fragments[1].x > fragments[0].x)               // Hebrew after Latin (LTR base)
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
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		let root = try #require(builder.root)
		// Stylesheets come straight from the DOM tree, not a second parse.
		let sheets = root.styleSheets()
		#expect(sheets.count == 1)

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

	@Test("@page size sets the page geometry")
	func atPageSize() async throws {
		let data = try await HTMLRenderer.renderPDF(html: "<style>@page { size: A4; margin: 0 }</style><p>x</p>")
		#if canImport(PDFKit)
		let document = try #require(PDFDocument(data: data))
		let bounds = try #require(document.page(at: 0)).bounds(for: .mediaBox)
		#expect(abs(bounds.width - 595.28) < 1.0)  // A4 width in points
		#expect(abs(bounds.height - 841.89) < 1.0) // A4 height in points
		#endif
	}

	@Test("@page landscape swaps width and height")
	func atPageLandscape() async throws {
		let data = try await HTMLRenderer.renderPDF(html: "<style>@page { size: A4 landscape }</style><p>x</p>")
		#if canImport(PDFKit)
		let document = try #require(PDFDocument(data: data))
		let bounds = try #require(document.page(at: 0)).bounds(for: .mediaBox)
		#expect(bounds.width > bounds.height)
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
