//
//  MultiPageMarkdownTests.swift
//  SwiftTextOCRTests
//

import Foundation
import Testing

@testable import SwiftTextOCR

/// Every page's blocks are measured from that page's own top, so the renderer
/// must order and merge them per page and keep the pages in sequence (#124).
struct MultiPageMarkdownTests {

	@Test("Pages stay in order with one separator between them")
	func pagesStayInOrder() {
		let markdown = DocumentBlockMarkdownRenderer.markdown(fromPages: [
			page(heading: "Page one heading", prefix: "Alpha", count: 6),
			page(heading: "Page two heading", prefix: "Beta", count: 6)
		])
		let lines = markdown.split(separator: "\n").map(String.init)
		#expect(lines.first == "# Page one heading")
		#expect(lines.filter { $0 == "---" }.count == 1)
		let separator = lines.firstIndex(of: "---")!
		#expect(lines[..<separator].allSatisfy { !$0.contains("Beta") && !$0.contains("Page two") })
		#expect(lines[separator...].allSatisfy { !$0.contains("Alpha") && !$0.contains("Page one") })
		#expect(lines[separator + 1] == "# Page two heading")
	}

	@Test("A short last page does not sort ahead of the first page")
	func shortLastPageComesLast() {
		// Page 2's only body line sits higher than anything but page 1's heading.
		let markdown = DocumentBlockMarkdownRenderer.markdown(fromPages: [
			page(heading: "Page one heading", prefix: "Alpha", count: 10),
			page(heading: nil, prefix: "Beta", count: 1)
		])
		let lines = markdown.split(separator: "\n").map(String.init)
		#expect(lines.first == "# Page one heading")
		#expect(lines.last?.contains("Beta line 01") == true)
		#expect(markdown.range(of: "Beta")!.lowerBound > markdown.range(of: "Alpha line 10")!.upperBound)
	}

	@Test("Paragraphs are not merged across a page break")
	func noMergingAcrossPages() {
		// Page 1 ends at y=120 and page 2 starts at y=122: on one page these
		// would be one continued paragraph.
		let first = DocumentBlockPage(blocks: [paragraph("End of page one.", y: 100)])
		let second = DocumentBlockPage(blocks: [paragraph("Start of page two.", y: 122)])
		let markdown = DocumentBlockMarkdownRenderer.markdown(fromPages: [first, second])
		#expect(markdown == "End of page one.\n\n---\n\nStart of page two.")
	}

	@Test("Heading levels are measured over the whole document")
	func headingLevelsUseWholeDocument() {
		let first = DocumentBlockPage(blocks: [
			paragraph("A body paragraph with enough text to set the body size.", y: 50)
		])
		let second = DocumentBlockPage(blocks: [
			paragraph("Only heading", y: 50, size: 22, bold: true),
			paragraph("More body text on the second page, also eleven point.", y: 100)
		])
		let markdown = DocumentBlockMarkdownRenderer.markdown(fromPages: [first, second])
		#expect(markdown.contains("# Only heading"))
	}

	@Test("No separator when disabled, and no doubled separator for an empty page")
	func separatorControl() {
		let pages = [
			page(heading: nil, prefix: "Alpha", count: 2),
			DocumentBlockPage(blocks: []),
			page(heading: nil, prefix: "Beta", count: 2)
		]
		let separated = DocumentBlockMarkdownRenderer.markdown(fromPages: pages)
		#expect(separated.components(separatedBy: "\n---\n").count == 2)

		let plain = DocumentBlockMarkdownRenderer.markdown(fromPages: pages, pageSeparator: false)
		#expect(!plain.contains("---"))
		#expect(plain.range(of: "Alpha")!.lowerBound < plain.range(of: "Beta")!.lowerBound)
	}

	@Test("The image resolver is told which page an image is on")
	func imageResolverGetsPageIndex() {
		let bounds = CGRect(x: 50, y: 200, width: 100, height: 100)
		let image = DocumentBlock(bounds: bounds, kind: .image(.init(caption: nil)))
		let markdown = DocumentBlockMarkdownRenderer.markdown(fromPages: [
			DocumentBlockPage(blocks: [image]),
			DocumentBlockPage(blocks: [image])
		]) { _, pageIndex in
			"page-\(pageIndex + 1).png"
		}
		#expect(markdown.range(of: "page-1.png")!.lowerBound < markdown.range(of: "page-2.png")!.lowerBound)
	}

	// MARK: - Helpers

	/// A page whose bounds start at its own top, with body lines 20pt apart,
	/// each its own paragraph separated by a visible gap.
	private func page(heading: String?, prefix: String, count: Int) -> DocumentBlockPage {
		var blocks: [DocumentBlock] = []
		var lines: [DocumentBlock.TextLine] = []
		if let heading {
			let block = paragraph(heading, y: 50, size: 22, bold: true)
			blocks.append(block)
			lines.append(.init(text: heading, bounds: block.bounds))
		}
		for index in 1...count {
			let text = "\(prefix) line \(String(format: "%02d", index)) on the page."
			let block = paragraph(text, y: 100 + CGFloat(index - 1) * 40)
			blocks.append(block)
			lines.append(.init(text: text, bounds: block.bounds))
		}
		// Hand the blocks over bottom-up so only sorting puts them in order.
		return DocumentBlockPage(blocks: blocks.reversed(), textLines: lines)
	}

	private func paragraph(_ text: String, y: CGFloat, size: CGFloat = 11, bold: Bool = false) -> DocumentBlock {
		let bounds = CGRect(x: 50, y: y, width: 400, height: 20)
		let run = StyleRun(text: text, style: TextStyle(fontSize: size, isBold: bold))
		return DocumentBlock(bounds: bounds, kind: .paragraph(.init(
			text: text, lines: [.init(runs: [run], bounds: bounds)])))
	}
}
