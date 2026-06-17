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
	/// Page margin in CSS pixels applied on all sides.
	public var pageMarginPx: Double

	public init(pageWidthPx: Double = 816, pageMarginPx: Double = 32) {
		self.pageWidthPx = pageWidthPx
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
	///   - options: Page geometry.
	public static func renderPDF(html: String, css: [String] = [], options: RenderOptions = RenderOptions()) async throws -> Data {
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		guard let root = builder.root else { throw RenderError.noDocument }

		let resolver = StyleResolver(authorStyleSheets: css)
		let styled = StyledElement.build(domElement: root, resolver: resolver)
		guard let rootBox = BoxTreeBuilder.build(from: styled) as? BlockBox else { throw RenderError.noRootBox }

		let fonts = FontBook()
		let engine = LayoutEngine(fonts: fonts)
		let contentWidth = max(0, options.pageWidthPx - 2 * options.pageMarginPx)
		let contentHeight = engine.layout(root: rootBox, contentWidth: contentWidth,
		                                  originX: options.pageMarginPx, originY: options.pageMarginPx)

		let pageHeightPx = contentHeight + 2 * options.pageMarginPx
		let painter = Painter(pageHeightPx: pageHeightPx, fonts: fonts)
		painter.paint(rootBox)

		return assemble(content: painter.stream, resources: painter.resources(),
		                pageWidthPx: options.pageWidthPx, pageHeightPx: pageHeightPx)
	}

	private static func assemble(content: PDFStream, resources: PDFDictionary, pageWidthPx: Double, pageHeightPx: Double) -> Data {
		let pdf = PDF()
		pdf.addObject(content)
		let page = PDFDictionary([
			("Type", "/Page"),
			("Parent", pdf.pages.reference),
			("MediaBox", PDFArray([0, 0, pageWidthPx * pxToPt, pageHeightPx * pxToPt])),
			("Contents", content.reference),
			("Resources", resources),
		])
		pdf.addPage(page)
		return pdf.write()
	}
}
