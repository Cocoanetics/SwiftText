//  HTMLRenderer.swift
//  SwiftTextRender
//
//  The public entry point: parse HTML, resolve styles, build and lay out the
//  box tree, paint it, and assemble a PDF — all cross-platform, with no WebKit.
//
//  This first version renders a single auto-height page (no pagination yet), so
//  the full document is visible for verifying layout. Real @page-sized,
//  paginated output is layered on next.

import Foundation
import SwiftTextHTML
import SwiftTextCSS
import SwiftTextPDFWriter

public struct RenderOptions {
	/// Page width in CSS pixels (default ≈ US Letter, 816px = 8.5in @96dpi).
	public var pageWidthPx: Double
	/// Page height in CSS pixels. `nil` produces a single auto-height page;
	/// otherwise content is paginated to this height (default ≈ US Letter,
	/// 1056px = 11in @96dpi).
	public var pageHeightPx: Double?
	/// Page margin in CSS pixels applied on all sides.
	public var pageMarginPx: Double

	public init(pageWidthPx: Double = 816, pageHeightPx: Double? = 1056, pageMarginPx: Double = 32) {
		self.pageWidthPx = pageWidthPx
		self.pageHeightPx = pageHeightPx
		self.pageMarginPx = pageMarginPx
	}
}

public enum RenderError: Error {
	case noDocument
	case noRootBox
}

/// Renders HTML (with optional CSS) to a PDF, cross-platform.
public enum HTMLRenderer {

	/// Render an HTML string to PDF bytes.
	///
	/// - Parameters:
	///   - html: The HTML source.
	///   - css: Additional author stylesheets, applied after any `<style>` the
	///     document carries (note: `<style>` extraction is added later; for now
	///     pass author CSS here).
	///   - fonts: A font book; register OpenType fonts on it to embed them and
	///     render arbitrary families/scripts. Defaults to base-14 only.
	///   - options: Page geometry.
	public static func renderPDF(html: String, css: [String] = [], fonts: FontBook = FontBook(), options: RenderOptions = RenderOptions()) async throws -> Data {
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		guard let root = builder.root else { throw RenderError.noDocument }

		// Author stylesheets: the document's own <style> elements first, then any
		// sheets supplied by the caller (which therefore win on equal specificity).
		let documentSheets = extractStyleSheets(html: html)
		let resolver = StyleResolver(authorStyleSheets: documentSheets + css)
		let styled = StyledElement.build(domElement: root, resolver: resolver)
		guard let rootBox = BoxTreeBuilder.build(from: styled) as? BlockBox else { throw RenderError.noRootBox }

		let engine = LayoutEngine(fonts: fonts)
		let margin = options.pageMarginPx
		let contentWidth = max(0, options.pageWidthPx - 2 * margin)
		// Lay the document out as a single tall column (origin at column y = 0).
		let columnHeight = engine.layout(root: rootBox, contentWidth: contentWidth, originX: margin, originY: 0)

		// Page height: fixed (paginated) or just enough for the whole column.
		let pageHeightPx = options.pageHeightPx ?? (columnHeight + 2 * margin)
		let slices = paginate(rootBox, columnHeight: columnHeight, pageHeightPx: pageHeightPx, margin: margin)

		let pdf = PDF()
		let fontBuilder = FontResourceBuilder(pdf: pdf)
		var pageObjects: [PDFDictionary] = []
		for slice in slices {
			let geometry = PageGeometry(pageWidthPx: options.pageWidthPx, pageHeightPx: pageHeightPx,
			                            marginPx: margin, columnTop: slice.top, sliceHeightPx: slice.bottom - slice.top)
			let painter = Painter(geometry: geometry, fonts: fonts, builder: fontBuilder)
			painter.paint(rootBox)
			pdf.addObject(painter.stream)
			let page = PDFDictionary([
				("Type", "/Page"),
				("Parent", pdf.pages.reference),
				("MediaBox", PDFArray([0, 0, options.pageWidthPx * pxToPt, pageHeightPx * pxToPt])),
				("Contents", painter.stream.reference),
				("Resources", fontBuilder.resourcesReference),
			])
			let annotations = painter.annotations()
			if !annotations.isEmpty {
				var references: [PDFValue] = []
				for annotation in annotations {
					pdf.addObject(annotation)
					references.append(annotation.reference)
				}
				page["Annots"] = PDFArray(references)
			}
			pdf.addPage(page)
			pageObjects.append(page)
		}
		// Build the shared font objects now that every page's glyph use is known.
		fontBuilder.finalize()
		addOutline(to: pdf, root: rootBox, slices: slices, pages: pageObjects, pageHeightPx: pageHeightPx, margin: margin)
		return pdf.write()
	}

	// MARK: - Bookmarks / outline

	/// Build a PDF outline (bookmarks) from the document's heading hierarchy.
	private static func addOutline(to pdf: PDF, root: BlockBox, slices: [(top: Double, bottom: Double)],
	                               pages: [PDFDictionary], pageHeightPx: Double, margin: Double) {
		var headings: [(level: Int, title: String, y: Double)] = []
		collectHeadings(root, into: &headings)
		guard !headings.isEmpty, !pages.isEmpty else { return }

		// Nest headings by level using a stack of open ancestors.
		var nodes: [(level: Int, title: String, y: Double, parent: Int?, children: [Int], dict: PDFDictionary)] = []
		var stack: [Int] = []
		for heading in headings {
			while let top = stack.last, nodes[top].level >= heading.level { stack.removeLast() }
			let index = nodes.count
			nodes.append((heading.level, heading.title, heading.y, stack.last, [], PDFDictionary()))
			if let parent = stack.last { nodes[parent].children.append(index) }
			stack.append(index)
		}

		func destination(forColumnY y: Double) -> PDFArray {
			var pageIndex = slices.count - 1
			for (index, slice) in slices.enumerated() where y >= slice.top - 0.5 && y < slice.bottom + 0.5 {
				pageIndex = index
				break
			}
			let pageY = margin + (y - slices[pageIndex].top)
			let topPt = (pageHeightPx - pageY) * pxToPt
			return PDFArray([pages[pageIndex].reference, "/XYZ", margin * pxToPt, topPt, "null"])
		}

		let outlineRoot = PDFDictionary([("Type", "/Outlines")])
		pdf.addObject(outlineRoot)
		for index in nodes.indices { pdf.addObject(nodes[index].dict) }

		func wire(_ siblings: [Int], parentReference: Data) {
			for (position, index) in siblings.enumerated() {
				let node = nodes[index]
				let dict = node.dict
				dict["Title"] = PDFString(node.title)
				dict["Parent"] = parentReference
				dict["Dest"] = destination(forColumnY: node.y)
				if position > 0 { dict["Prev"] = nodes[siblings[position - 1]].dict.reference }
				if position < siblings.count - 1 { dict["Next"] = nodes[siblings[position + 1]].dict.reference }
				if !node.children.isEmpty {
					dict["First"] = nodes[node.children.first!].dict.reference
					dict["Last"] = nodes[node.children.last!].dict.reference
					dict["Count"] = node.children.count
					wire(node.children, parentReference: dict.reference)
				}
			}
		}

		let roots = nodes.indices.filter { nodes[$0].parent == nil }
		wire(roots, parentReference: outlineRoot.reference)
		outlineRoot["First"] = nodes[roots.first!].dict.reference
		outlineRoot["Last"] = nodes[roots.last!].dict.reference
		outlineRoot["Count"] = roots.count
		pdf.catalog["Outlines"] = outlineRoot.reference
	}

	private static func collectHeadings(_ box: Box, into headings: inout [(level: Int, title: String, y: Double)]) {
		guard let block = box as? BlockBox else { return }
		if let tag = block.element?.localName, tag.count == 2, tag.hasPrefix("h"),
		   let level = Int(tag.dropFirst()), (1 ... 6).contains(level) {
			let title = headingTitle(block)
			if !title.isEmpty { headings.append((level, title, block.y)) }
		}
		if !block.establishesInlineContext {
			for child in block.children { collectHeadings(child, into: &headings) }
		}
	}

	private static func headingTitle(_ box: BlockBox) -> String {
		var words: [String] = []
		func gather(_ box: Box) {
			guard let block = box as? BlockBox else { return }
			for line in block.lines { for fragment in line.fragments { words.append(fragment.text) } }
			for child in block.children { gather(child) }
		}
		gather(box)
		return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Split the laid-out column into page slices, breaking only at line and
	/// block boundaries where possible.
	private static func paginate(_ root: BlockBox, columnHeight: Double, pageHeightPx: Double, margin: Double) -> [(top: Double, bottom: Double)] {
		let contentHeight = max(1, pageHeightPx - 2 * margin)
		guard columnHeight > contentHeight + 0.5 else {
			return [(0, columnHeight)]
		}

		var breaks: Set<Double> = []
		collectBreaks(root, into: &breaks)
		let sortedBreaks = breaks.sorted()

		var slices: [(top: Double, bottom: Double)] = []
		var top = 0.0
		while top < columnHeight - 0.5 {
			let target = top + contentHeight
			if target >= columnHeight {
				slices.append((top, columnHeight))
				break
			}
			// The furthest break strictly inside (top, target]; force a hard break
			// if a single line/block is taller than the page.
			let candidate = sortedBreaks.last { $0 > top + 0.5 && $0 <= target + 0.5 }
			let bottom = (candidate ?? target) > top ? (candidate ?? target) : target
			slices.append((top, bottom))
			top = bottom
		}
		return slices.isEmpty ? [(0, columnHeight)] : slices
	}

	/// Collect candidate page-break y-coordinates: line and block edges.
	private static func collectBreaks(_ box: Box, into ys: inout Set<Double>) {
		guard let block = box as? BlockBox else { return }
		ys.insert(block.y)
		ys.insert(block.y + block.height)
		if block.establishesInlineContext {
			for line in block.lines {
				ys.insert(line.y)
				ys.insert(line.y + line.height)
			}
		} else {
			for child in block.children { collectBreaks(child, into: &ys) }
		}
	}

	/// Collect the CSS text of every `<style>` element, in document order.
	///
	/// Extracted from the raw HTML because SwiftTextHTML's parser delivers
	/// `<style>` content as a CDATA event that the DOM builder discards.
	/// (`<link rel="stylesheet">` fetching is not done yet.)
	static func extractStyleSheets(html: String) -> [String] {
		let pattern = "<style[^>]*>([\\s\\S]*?)</style>"
		guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
			return []
		}
		let text = html as NSString
		var sheets: [String] = []
		for match in regex.matches(in: html, range: NSRange(location: 0, length: text.length)) where match.numberOfRanges > 1 {
			let css = text.substring(with: match.range(at: 1))
			if !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				sheets.append(css)
			}
		}
		return sheets
	}

}
