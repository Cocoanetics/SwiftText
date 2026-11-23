//  InlineBlockTests.swift
//  SwiftTextRenderTests

import Foundation
import Testing
@testable import SwiftTextRender
import SwiftTextCSS
import SwiftTextHTML

/// `display: inline-block` boxes sit in a line as one box each: the labels,
/// columns and buttons of a receipt mail such as Apple's credit note.
@Suite("Inline-block layout")
struct InlineBlockTests {

	@Test("Two columns of 50% share one line")
	func columnsShareTheLine() async throws {
		let column = "display: inline-block; width: 50%; vertical-align: top"
		let html = "<div id=\"row\" style=\"width: 400px\">"
			+ "<div style=\"\(column)\"><p style=\"margin: 0\">Name</p><p style=\"margin: 0\">Street</p></div>"
			+ "<div style=\"\(column)\"><p style=\"margin: 0\">Total</p></div></div>"
		let root = try await layout(html)
		let row = try #require(blocks(root, "div").first)
		#expect(row.lines.count == 1)
		let columns = atomicBlocks(in: row)
		#expect(columns.count == 2)
		#expect(columns[0].x == row.x)
		#expect(abs(columns[1].x - (row.x + 200)) < 0.01)
		#expect(columns.allSatisfy { abs($0.width - 200) < 0.01 })
		// Aligned at the top; the line is as tall as the taller column.
		#expect(columns[0].y == row.y && columns[1].y == row.y)
		#expect(abs(row.height - columns[0].height) < 0.01)
		// The content moved with its column.
		let total = try #require(blocks(columns[1], "p").first?.lines.first?.fragments.first)
		#expect(total.text == "Total")
		#expect(abs(total.x - columns[1].x) < 0.01)
	}

	@Test("An inline-block shrinks to its content and keeps its margin")
	func shrinksToFitWithMargin() async throws {
		let html = "<div id=\"row\"><p style=\"display: inline-block; margin: 0 5px 0 0\">Sequence:</p>"
			+ "<p style=\"display: inline-block; margin: 0\">1-23</p></div>"
		let root = try await layout(html)
		let row = try #require(blocks(root, "div").first)
		#expect(row.lines.count == 1)
		let boxes = atomicBlocks(in: row)
		#expect(boxes.count == 2)
		let labelWidth = try #require(boxes[0].lines.first?.width)
		#expect(abs(boxes[0].width - labelWidth) < 0.01)
		#expect(abs(boxes[1].x - (boxes[0].x + boxes[0].width + 5)) < 0.01)
		// Both sit on the line's baseline.
		let line = try #require(row.lines.first)
		let baselines = boxes.compactMap { $0.lines.first.map { $0.y + $0.baseline } }
		#expect(baselines.allSatisfy { abs($0 - (line.y + line.baseline)) < 0.01 })
	}

	@Test("An inline-block too wide for the rest of the line moves to the next")
	func wrapsWhole() async throws {
		let box = "display: inline-block; width: 120px"
		let root = try await layout("<div style=\"width: 200px\"><span style=\"\(box)\">a</span><span style=\"\(box)\">b</span></div>")
		let row = try #require(blocks(root, "div").first)
		#expect(row.lines.count == 2)
		let boxes = atomicBlocks(in: row)
		#expect(boxes[1].x == boxes[0].x)
		#expect(boxes[1].y >= boxes[0].y + boxes[0].height)
	}

	@Test("A button inside a link is a filled box, linked but not underlined")
	func buttonInLink() async throws {
		let html = "<p><a href=\"https://example.com/off\"><button style=\"background-color: #0000ff; color: #fff; "
			+ "border-width: 0; padding: 8px 15px; min-width: 260px; text-align: center\">Turn Off</button></a></p>"
		let root = try await layout(html)
		let paragraph = try #require(blocks(root, "p").first)
		let button = try #require(atomicBlocks(in: paragraph).first)
		#expect(abs(button.width - 290) < 0.01)
		#expect(button.linkHref == "https://example.com/off")
		#expect(!button.style.underline)
		let words = try #require(button.lines.first?.fragments)
		#expect(words.map(\.text) == ["Turn", "Off"])
		#expect(words.allSatisfy { $0.href == "https://example.com/off" })
		// Centred within the button.
		let middle = (words[0].x + words[1].x + words[1].width) / 2
		#expect(abs(middle - (button.x + button.width / 2)) < 0.5)

		let pdf = try await render(html)
		#expect(pdf.contains("0 0 1 rg"))
		#expect(pdf.contains("/URI (https://example.com/off)"))
	}

	@Test("An inline-block moves with its line when a table cell is vertically centred")
	func inlineBlockInMiddleAlignedCell() async throws {
		let html = "<table><tr><td id=\"short\"><span style=\"display: inline-block; padding: 8px\">Off</span></td>"
			+ "<td><div style=\"height: 100px\">tall</div></td></tr></table>"
		let root = try await layout(html)
		let cell = try #require(blocks(root, "td").first)
		let line = try #require(cell.lines.first)
		let box = try #require(atomicBlocks(in: cell).first)
		// Centred, not left at the top of the cell…
		#expect(line.y > cell.y + 20)
		// …and the inline-block and its text went with the line.
		let word = try #require(box.lines.first?.fragments.first)
		#expect(abs(word.y - (box.y + 8)) < 0.01)
		#expect(box.y >= line.y - 0.01 && box.y + box.height <= line.y + line.height + 0.01)
	}

	@Test("An inline box's margin and padding take up room on the line")
	func inlineBoxSpacing() async throws {
		let root = try await layout("<p><span style=\"margin-right: 10px\">VAT</span><span style=\"padding-left: 4px\">19,17</span></p>")
		let line = try #require(blocks(root, "p").first?.lines.first)
		#expect(line.fragments.count == 2)
		let gap = line.fragments[1].x - (line.fragments[0].x + line.fragments[0].width)
		#expect(abs(gap - 14) < 0.01)
	}

	@Test("An inline box's percentage padding resolves against the containing block")
	func inlineBoxPercentagePadding() async throws {
		let root = try await layout("<div style=\"width: 400px\"><span>VAT</span><span style=\"padding-left: 10%\">19,17</span></div>")
		let line = try #require(blocks(root, "div").first?.lines.first)
		#expect(line.fragments.count == 2)
		let gap = line.fragments[1].x - (line.fragments[0].x + line.fragments[0].width)
		#expect(abs(gap - 40) < 0.01)
	}

	@Test("An inline box's leading spacing moves to the next line with its first word")
	func leadingSpacingWraps() async throws {
		let root = try await layout("<div style=\"width: 60px\">aaaaa <span style=\"padding-left: 20px\">bbbbb</span></div>")
		let div = try #require(blocks(root, "div").first)
		#expect(div.lines.count == 2)
		let word = try #require(div.lines.last?.fragments.first)
		#expect(word.text == "bbbbb")
		#expect(abs(word.x - (div.x + 20)) < 0.01)
	}

	@Test("Logical and physical padding compete in cascade order")
	func logicalPhysicalCascade() async throws {
		let root = try await layout("<div style=\"padding-inline: 10px; padding-left: 20px\">x</div>"
			+ "<p style=\"padding-left: 20px; padding-inline: 10px\">y</p>"
			+ "<style>ul { padding-left: 0 }</style><ul><li>z</li></ul>")
		let div = try #require(blocks(root, "div").first)
		#expect(div.style.padding.left == .px(20) && div.style.padding.right == .px(10))
		let paragraph = try #require(blocks(root, "p").first)
		#expect(paragraph.style.padding.left == .px(10))
		// The author's physical padding beats the UA's padding-inline-start.
		let list = try #require(blocks(root, "ul").first)
		#expect(list.style.padding.left == .px(0))
	}

	@Test("padding-inline sets the start and end padding")
	func paddingInlineShorthand() async throws {
		let root = try await layout("<div style=\"padding-inline: 0 20px\">x</div><p style=\"padding-inline: 7px\">y</p>")
		let div = try #require(blocks(root, "div").first)
		#expect(div.style.padding.left == .px(0) && div.style.padding.right == .px(20))
		let paragraph = try #require(blocks(root, "p").first)
		#expect(paragraph.style.padding.left == .px(7) && paragraph.style.padding.right == .px(7))
	}

	@Test("A weight above 500 selects the bold face")
	func semiboldIsBold() async throws {
		let fonts = FontBook()
		var style = ComputedStyle.initial
		style.fontFamily = ["Helvetica"]
		style.fontWeight = 700
		let bold = fonts.font(for: style).key
		style.fontWeight = 550
		#expect(fonts.font(for: style).key == bold)
		style.fontWeight = 500
		#expect(fonts.font(for: style).key != bold)
	}

	@Test("border-radius rounds backgrounds, borders and images")
	func borderRadius() async throws {
		let square = try await render("<div style=\"background-color: #ff0000; width: 100px; height: 40px\"></div>")
		#expect(!square.contains(" c\n"))
		let rounded = try await render("<div style=\"background-color: #ff0000; width: 100px; height: 40px; border-radius: 8px\"></div>")
		#expect(rounded.contains(" c\n"))

		let icon = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR42mOQTL/0H4gZGEAEiAMAPksHR3+zUn4AAAAASUVORK5CYII="
		let image = try await render("<p><img src=\"\(icon)\" width=\"60\" height=\"60\" style=\"border-radius: 14px; border: 1px solid #808080\"></p>")
		// The image is clipped to its rounded box, and the border is a ring.
		#expect(image.contains("W\nn"))
		#expect(image.contains("f*"))

		let root = try await layout("<div style=\"width: 100px; height: 40px; border-radius: 50%\"></div>")
		let div = try #require(blocks(root, "div").first)
		#expect(div.style.usedBorderRadius(width: div.width, height: div.height) == 20)
	}

	// MARK: - Helpers

	private func layout(_ html: String, width: Double = 600) async throws -> BlockBox {
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		let root = try #require(builder.root)
		let styled = StyledElement.build(domElement: root, resolver: StyleResolver(authorStyleSheets: root.styleSheets()))
		let box = try #require(BoxTreeBuilder.build(from: styled) as? BlockBox)
		LayoutEngine(fonts: FontBook()).layout(root: box, contentWidth: width, originX: 0, originY: 0)
		return box
	}

	private func render(_ html: String) async throws -> String {
		let data = try await HTMLRenderer.renderPDF(html: html, options: RenderOptions(compressStreams: false))
		return String(decoding: data, as: UTF8.self)
	}

	/// The blocks for `name` elements, looking into inline-blocks too.
	private func blocks(_ box: BlockBox, _ name: String) -> [BlockBox] {
		var result: [BlockBox] = box.element?.localName == name ? [box] : []
		for child in box.children {
			if let block = child as? BlockBox { result += blocks(block, name) }
		}
		for inner in atomicBlocks(in: box) { result += blocks(inner, name) }
		return result
	}

	/// The inline-blocks placed in a block's lines, in order.
	private func atomicBlocks(in box: BlockBox) -> [BlockBox] {
		box.lines.flatMap(\.fragments).compactMap { fragment in
			if case .block(let block, _, _)? = fragment.inlineControl { return block }
			return nil
		}
	}
}
