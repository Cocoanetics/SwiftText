//  HTMLEmailLayoutTests.swift
//  SwiftTextRenderTests

import Foundation
import Testing
@testable import SwiftTextRender
import SwiftTextCSS
import SwiftTextHTML

/// HTML email is laid out with nested tables, presentational attributes and
/// remote images, and arrives with CR LF line ends. These cover what a receipt
/// like Google's "Payment received" mail needs to render as a browser shows it.
@Suite("HTML email layout")
struct HTMLEmailLayoutTests {
	/// A 4×1 palette PNG with a transparent entry, like most email logos.
	private static let logoPNG = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAABCAMAAADO4v//AAAACVBMVEX///9ChfTqQzVlUTG7AAAAAXRSTlMAQObYZgAAAA1JREFUeNpjYGBkYgAAAAwABBbGh4MAAAAASUVORK5CYII="
	/// A 2×2 RGBA PNG.
	private static let iconPNG = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR42mOQTL/0H4gZGEAEiAMAPksHR3+zUn4AAAAASUVORK5CYII="
	private static let logo = "data:image/png;base64,\(logoPNG)"
	private static let icon = "data:image/png;base64,\(iconPNG)"

	// MARK: - Inline images

	@Test("An inline image sits on the line between the words around it")
	func inlineImageSharesTheLine() async throws {
		let root = try await layout("<p>Before <img src=\"\(Self.icon)\" width=\"20\" height=\"20\"> after</p>")
		let paragraph = try #require(blocks(root, "p").first)
		#expect(paragraph.lines.count == 1)
		let line = try #require(paragraph.lines.first)
		#expect(line.fragments.map(\.text) == ["Before", "", "after"])
		let replaced = line.fragments.first { $0.isReplaced }
		let image = try #require(replaced)
		guard case .image(_, let metrics, let top)? = image.inlineControl else {
			Issue.record("expected an image fragment")
			return
		}
		#expect(metrics.contentWidth == 20 && metrics.contentHeight == 20)
		// Baseline-aligned: the image's bottom sits on the text baseline.
		#expect(abs(line.y + top + 20 - (line.y + line.baseline)) < 0.01)
		#expect(line.height >= 20)
		#expect(line.fragments[2].x >= image.x + image.width)
	}

	@Test("An image inside a link is drawn and becomes a link")
	func linkedImageIsDrawn() async throws {
		let html = "<a href=\"https://example.com/help\"><img src=\"\(Self.icon)\" width=\"24\" height=\"24\"></a>"
		let pdf = try await render(html)
		#expect(pdf.contains("/Subtype /Image"))
		#expect(pdf.contains("/SMask "))
		#expect(pdf.contains(" Do"))
		#expect(pdf.contains("/URI (https://example.com/help)"))
		#expect(!pdf.contains("0.9 0.9 0.9 rg"))
	}

	@Test("An inline image paints its background and border")
	func inlineImageDecorations() async throws {
		let html = "<p>x <img src=\"\(Self.icon)\" width=\"10\" height=\"10\" border=\"2\" "
			+ "style=\"background-color: #ff0000; border-color: #00ff00; padding: 3px\"></p>"
		let pdf = try await render(html)
		#expect(pdf.contains("1 0 0 rg")) // the background
		#expect(pdf.contains("0 1 0 rg")) // the border
		// Background and border cover the border box: 2 + 3 + 10 + 3 + 2 = 20.
		#expect(pdf.contains(" 20 20 re"))
	}

	@Test("max-width: 100% scales an image down, height and all")
	func maxWidthScalesImage() async throws {
		let html = "<div style=\"width: 100px\"><img src=\"\(Self.logo)\" style=\"width: 400px; max-width: 100%\"></div>"
		let root = try await layout(html)
		let fragment = try #require(replacedFragments(root).first)
		guard case .image(_, let metrics, _)? = fragment.inlineControl else {
			Issue.record("expected an image fragment")
			return
		}
		#expect(metrics.contentWidth == 100)
		#expect(metrics.contentHeight == 25)
	}

	@Test("vertical-align: middle centres an image on the text")
	func middleAlignedImage() async throws {
		let root = try await layout("<p style=\"font-size: 16px\">Text <img src=\"\(Self.icon)\" width=\"40\" height=\"40\" align=\"middle\"></p>")
		let line = try #require(blocks(root, "p").first?.lines.first)
		let replaced = line.fragments.first { $0.isReplaced }
		let image = try #require(replaced)
		guard case .image(_, _, let top)? = image.inlineControl else {
			Issue.record("expected an image fragment")
			return
		}
		// Centred half an x-height (here 0.25em) above the baseline.
		#expect(abs((line.baseline - 4) - (top + 20)) < 0.01)
	}

	// MARK: - Remote images

	@Test("Remote images load through the configured loader, once per source")
	func remoteImagesUseTheLoader() async throws {
		let requests = RequestLog()
		let png = try #require(Data(base64Encoded: Self.iconPNG))
		var options = RenderOptions(compressStreams: false)
		options.imageLoader = { url in
			await requests.record(url)
			return png
		}
		var warnings: [String] = []
		let html = """
			<img src="https://example.com/logo.png" width="10"><img src="https://example.com/logo.png" width="10">
			<div style="display: none"><img src="https://tracker.example.com/open.gif"></div>
			"""
		let pdf = try await HTMLRenderer.renderPDF(html: html, options: options) { warnings.append($0) }
		#expect(warnings.isEmpty)
		#expect(await requests.urls == [URL(string: "https://example.com/logo.png")!])
		#expect(String(decoding: pdf, as: UTF8.self).contains("/Subtype /Image"))
	}

	@Test("A remote image that fails to load warns and draws a placeholder")
	func failedRemoteImage() async throws {
		var options = RenderOptions(compressStreams: false)
		options.imageLoader = { _ in throw ImageLoadingError.httpStatus(404) }
		var warnings: [String] = []
		let pdf = try await HTMLRenderer.renderPDF(
			html: "<img src=\"https://example.com/gone.png\" width=\"30\" height=\"10\">", options: options) { warnings.append($0) }
		#expect(warnings.count == 1)
		#expect(warnings.first?.contains("https://example.com/gone.png") == true)
		#expect(warnings.first?.contains("HTTP 404") == true)
		#expect(String(decoding: pdf, as: UTF8.self).contains("0.9 0.9 0.9 rg"))
	}

	@Test("Without an image loader nothing is fetched")
	func offlineRendering() async throws {
		var warnings: [String] = []
		_ = try await HTMLRenderer.renderPDF(
			html: "<img src=\"https://example.com/logo.png\">", options: RenderOptions(imageLoader: nil)) { warnings.append($0) }
		#expect(warnings.count == 1)
		#expect(warnings.first?.contains("is not a local file") == true)
	}

	#if canImport(Darwin)
	/// The limit holds while the body arrives: an oversized response is cut off,
	/// never buffered whole.
	@Test("The default loader stops a download that outgrows its limit", arguments: ["streamed", "declared"])
	func oversizedDownloadStops(_ kind: String) async throws {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [OversizedImageProtocol.self]
		let url = try #require(URL(string: "https://example.com/huge.png?\(kind)"))
		let error = await #expect(throws: ImageLoadingError.self) {
			_ = try await HTMLRenderer.downloadImage(from: url, limit: 100_000, configuration: configuration)
		}
		guard case .tooLarge(_, let limit)? = error else {
			Issue.record("expected the download to be stopped, got \(String(describing: error))")
			return
		}
		#expect(limit == 100_000)
	}
	#endif

	@Test("Image sources resolve to the URL a browser would fetch")
	func remoteImageURLs() throws {
		let page = try #require(URL(string: "https://example.com/mail/view.html"))
		let folder = URL(fileURLWithPath: "/tmp/mail/")
		#expect(HTMLRenderer.remoteImageURL("https://example.com/a.png", baseURL: nil)?.absoluteString == "https://example.com/a.png")
		#expect(HTMLRenderer.remoteImageURL("//cdn.example.com/a.png", baseURL: nil)?.absoluteString == "https://cdn.example.com/a.png")
		#expect(HTMLRenderer.remoteImageURL("cid:logo@example.com", baseURL: nil)?.scheme == "cid")
		#expect(HTMLRenderer.remoteImageURL("logo.png", baseURL: page)?.absoluteString == "https://example.com/mail/logo.png")
		#expect(HTMLRenderer.remoteImageURL("logo.png", baseURL: folder) == nil)
		#expect(HTMLRenderer.remoteImageURL("logo.png", baseURL: nil) == nil)
		#expect(HTMLRenderer.remoteImageURL("file:///tmp/logo.png", baseURL: nil) == nil)
		#expect(HTMLRenderer.remoteImageURL("data:image/png;base64,AAAA", baseURL: nil) == nil)
	}

	// MARK: - Tables

	@Test("A table without a width shrinks to fit its columns")
	func autoWidthTableShrinks() async throws {
		let root = try await layout("<table><tr><td>A</td><td>B</td></tr></table>", width: 400)
		let table = try #require(blocks(root, "table").first)
		let cells = blocks(root, "td")
		let spacing = 2.0 * 3
		#expect(abs(table.width - (cells[0].width + cells[1].width + spacing)) < 0.01)
		#expect(table.width < 100)
	}

	@Test("A table's width is shared out among the columns that set none")
	func explicitTableWidthExpandsAutoColumns() async throws {
		let html = "<table width=\"300\" cellspacing=\"0\" cellpadding=\"0\"><tr><td width=\"50\">A</td><td>B</td></tr></table>"
		let root = try await layout(html)
		let cells = blocks(root, "td")
		#expect(abs(cells[0].width - 50) < 0.01)
		#expect(abs(cells[1].width - 250) < 0.01)
		#expect(blocks(root, "table").first?.width == 300)
	}

	@Test("A cell's pixel width holds against longer content, which wraps")
	func cellWidthWrapsContent() async throws {
		let html = "<table cellspacing=\"0\" cellpadding=\"0\"><tr><td width=\"60\">several words that would be wide</td><td>x</td></tr></table>"
		let cell = try #require(blocks(try await layout(html), "td").first)
		#expect(cell.width == 60)
		#expect(cell.lines.count > 1)
	}

	/// The footer of Google's receipts: each link is a nested two-column table
	/// (a fixed-width icon cell, then the label). A nested table's intrinsic
	/// width must be the sum of its columns, or the label column is crushed to a
	/// letter or two per line.
	@Test("A nested table's columns add up in its cell's intrinsic width")
	func nestedTableIntrinsicWidth() async throws {
		func link(_ label: String) -> String {
			"""
			<td><table cellspacing="0" cellpadding="0"><tr>
			<td style="width:50px"><a href="https://example.com"><img src="\(Self.icon)" width="24"></a></td>
			<td style="text-align:left"><a href="https://example.com"><span style="word-break:break-word">\(label)</span></a></td>
			</tr></table></td>
			"""
		}
		let html = """
			<table cellspacing="0" cellpadding="0" style="margin: 0 auto"><tr><td style="padding: 0 50px 0 25px">
			<table cellspacing="0" cellpadding="0"><tr>\(link("Help center"))<td width="10"></td>\(link("Contact us"))</tr></table>
			</td></tr></table>
			"""
		let root = try await layout(html, width: 536)
		let labels = blocks(root, "td").filter { cell in
			cell.lines.contains { line in line.fragments.contains { $0.text == "center" || $0.text == "us" } }
		}
		#expect(labels.count == 2)
		for label in labels { #expect(label.lines.count == 1) }
	}

	@Test("A nested collapsed-border table measures with its resolved borders")
	func nestedCollapsedTableMeasuresResolvedBorders() async throws {
		let inner = "<table style=\"border-collapse: collapse\"><tr><td style=\"border: 4px solid black; padding: 0\">A</td><td style=\"border: 4px solid black; padding: 0\">B</td></tr></table>"
		let alone = try #require(blocks(try await layout(inner, width: 400), "table").first)
		let nested = try await layout("<table cellspacing=\"0\" cellpadding=\"0\"><tr><td>\(inner)</td></tr></table>", width: 400)
		let nestedTable = try #require(blocks(nested, "table").last)
		#expect(abs(nestedTable.width - alone.width) < 0.01)
	}

	// MARK: - Centring

	@Test("Auto margins centre a block narrower than its container")
	func autoMarginsCentre() async throws {
		let root = try await layout("<div style=\"width: 200px; margin: 0 auto\">x</div>", width: 600)
		#expect(blocks(root, "div").first?.x == 200)
	}

	@Test("<center> centres a table without centring the text in its cells")
	func centerElement() async throws {
		let html = "<center><table style=\"width: 300px\" cellspacing=\"0\" cellpadding=\"0\"><tr><td>text</td></tr></table></center>"
		let root = try await layout(html, width: 600)
		let table = try #require(blocks(root, "table").first)
		#expect(table.x == 150)
		let cell = try #require(blocks(root, "td").first)
		#expect(cell.lines.first?.fragments.first?.x == cell.x)
	}

	@Test("A cell with align=center centres a nested table")
	func alignedCellCentresNestedTable() async throws {
		let html = """
			<table width="400" cellspacing="0" cellpadding="0"><tr><td align="center">
			<table width="100"><tr><td>x</td></tr></table>
			</td></tr></table>
			"""
		let tables = blocks(try await layout(html, width: 600), "table")
		#expect(tables.count == 2)
		#expect(tables[1].x - tables[0].x == 150)
	}

	@Test("Table cells are vertically centred by default")
	func cellsAreVerticallyCentred() async throws {
		let html = "<table cellspacing=\"0\" cellpadding=\"0\"><tr><td style=\"height: 100px\">tall</td><td>mid</td></tr></table>"
		let cells = blocks(try await layout(html), "td")
		let line = try #require(cells[1].lines.first)
		#expect(abs((line.y + line.height / 2) - (cells[1].y + cells[1].height / 2)) < 0.5)
	}

	// MARK: - Blocks where tables and inline boxes do not expect them

	/// Billings Pro's mail centres its column in `<td style="display: block">`,
	/// which rendered as an empty page.
	@Test("A cell restyled display: block keeps its content, centred at its max-width")
	func blockStyledCell() async throws {
		let html = """
			<table width="100%" cellspacing="0" cellpadding="0"><tr>
			<td></td>
			<td style="display: block; max-width: 300px; margin: 0 auto; padding: 0">Payment Declined</td>
			<td></td>
			</tr></table>
			"""
		let root = try await layout(html, width: 600)
		let cells = blocks(root, "td")
		try #require(cells.count == 3)
		let content = cells[1]
		#expect(content.lines.first?.fragments.map(\.text) == ["Payment", "Declined"])
		#expect(content.width == 300)
		#expect(content.x == 150)
	}

	/// Audible's covers: `<a href="…"><img style="display: block"></a>`.
	@Test("A block image inside a link is drawn")
	func blockImageInLink() async throws {
		let html = """
			<table><tr><td><a href="https://example.com/book">
			<img src="\(Self.icon)" width="24" height="24" style="display: block">
			</a></td></tr></table>
			"""
		let pdf = try await render(html)
		#expect(pdf.contains("/Subtype /Image"))
		#expect(occurrences(of: " Do", in: pdf) == 1)
	}

	@Test("A block image moves to the next page whole, not cut where the cell beside it breaks")
	func blockImageIsNotSplitAcrossPages() async throws {
		let lines = (1...20).map { "line \($0)" }.joined(separator: "<br>")
		let html = """
			<table cellspacing="0" cellpadding="0"><tr>
			<td style="font-size: 10px; line-height: 20px">\(lines)</td>
			<td style="vertical-align: top"><div style="height: 250px"></div>\
			<img src="\(Self.icon)" width="100" height="100" style="display: block"></td>
			</tr></table>
			"""
		// The page ends at 300px, inside the image (250–350px), where the lines
		// of the first cell offer breaks at every 20px.
		let options = RenderOptions(pageWidthPx: 400, pageHeightPx: 300, pageMarginPx: 0, compressStreams: false)
		let data = try await HTMLRenderer.renderPDF(html: html, options: options)
		let pdf = String(decoding: data, as: UTF8.self)
		#expect(occurrences(of: "/Type /Page", in: pdf) - occurrences(of: "/Type /Pages", in: pdf) == 2)
		// Drawn once, on the second page: not also as a sliver on the first.
		#expect(occurrences(of: " Do", in: pdf) == 1)
	}

	// MARK: - End to end

	/// The structure of Google's "Payment received" receipt, which rendered
	/// with a 66-pixel header rule, no logo, an indented first line and its
	/// footer links broken into columns of two letters.
	@Test("A receipt laid out with tables and attributes renders as a browser shows it")
	func receiptLayout() async throws {
		let html = """
			<!doctype html>\r
			<html><body>\r
			<center><table border=0 cellpadding=0 cellspacing=0 style="min-width: 600px; width: 600px; max-width: 600px; margin:0 auto;" align=center>\r
			<tr><td class=logo style="border-bottom: 1px solid #bdbdbd; padding: 0px 32px;">\r
			<a href=#><img src="\(Self.logo)" width=250 alt="Logo" vspace=8 align=left></a>\r
			</td></tr></table></center>\r
			<center><table border=0 cellpadding=0 cellspacing=0 style="width: 600px; margin:0 auto;" align=center><tr><td>\r
			<div class=amount style="margin: 0px 32px 32px 32px; font-size: 14px; line-height:21px;">\r
			    Your payment of <span style=white-space:nowrap>€60.96</span> (reference CLOUD x7MZGH on Mastercard) was applied to Google Cloud Platform &amp; APIs on Nov 1, 2026.\r
			  </div>\r
			</td></tr></table></center>\r
			</body></html>\r
			"""
		let root = try await layout(html, width: 752)

		let logoCell = try #require(blocks(root, "td").first)
		#expect(logoCell.width == 600) // its bottom border is the header rule
		let logo = try #require(replacedFragments(logoCell).first)
		guard case .image(_, let metrics, _)? = logo.inlineControl else {
			Issue.record("expected the logo inline")
			return
		}
		#expect(metrics.contentWidth == 250)
		#expect(metrics.contentY == 8)

		let tables = blocks(root, "table")
		#expect(tables.allSatisfy { $0.x == 76 }) // centred: (752 - 600) / 2

		let amount = try #require(blocks(root, "div").first { $0.element?.attributeValue("class") == "amount" })
		#expect(amount.lines.count > 1)
		// Every line starts at the paragraph's edge: no CR LF "word" indents one.
		for line in amount.lines {
			#expect(abs((line.fragments.first?.x ?? 0) - amount.x) < 0.01)
			#expect(!line.fragments.contains { $0.text.contains("\r") })
		}
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

	private func blocks(_ box: BlockBox, _ name: String) -> [BlockBox] {
		var result: [BlockBox] = box.element?.localName == name ? [box] : []
		for child in box.children {
			if let block = child as? BlockBox { result += blocks(block, name) }
		}
		return result
	}

	private func occurrences(of needle: String, in haystack: String) -> Int {
		haystack.components(separatedBy: needle).count - 1
	}

	private func replacedFragments(_ box: BlockBox) -> [TextFragment] {
		box.lines.flatMap { $0.fragments.filter(\.isReplaced) }
			+ box.children.compactMap { $0 as? BlockBox }.flatMap(replacedFragments)
	}
}

#if canImport(Darwin)
/// Serves an image far larger than any limit: streamed in chunks, or announced
/// up front by its Content-Length (`?declared`).
private final class OversizedImageProtocol: URLProtocol, @unchecked Sendable {
	override static func canInit(with request: URLRequest) -> Bool { true }
	override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		let declared = request.url?.query == "declared"
		guard let url = request.url,
		      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
		                                     headerFields: declared ? ["Content-Length": "100000000"] : [:]) else { return }
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		let chunk = Data(repeating: 0x89, count: 64 * 1024)
		for _ in 0 ..< (declared ? 1 : 32) {
			client?.urlProtocol(self, didLoad: chunk)
		}
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}
#endif

/// The URLs an image loader was asked for, in order.
private actor RequestLog {
	private(set) var urls: [URL] = []

	func record(_ url: URL) {
		urls.append(url)
	}
}
