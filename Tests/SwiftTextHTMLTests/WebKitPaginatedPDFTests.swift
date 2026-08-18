//  WebKitPaginatedPDFTests.swift
//  SwiftTextHTMLTests
//
//  Paginated PDF export goes through the platform print pipeline —
//  `NSPrintOperation` on macOS, `UIPrintPageRenderer` on iOS. Both are APIs onto
//  the same WebKit paginator, and this suite is what holds them to that: the
//  expectations below are not per-platform.

#if os(macOS) || os(iOS)
import Foundation
import PDFKit
import Testing
@testable import SwiftTextHTML

@Suite("WebKit paginated PDF export")
@MainActor
struct WebKitPaginatedPDFTests {
	private let a4 = CGSize(width: 595.28, height: 841.89)

	private func paginate(_ html: String) async throws -> PDFDocument {
		let browser = WebKitBrowser(htmlString: html)
		browser.frameSize = a4
		// Let WebKit paginate rather than stretching the frame to the content.
		browser.preserveFrameHeight = true
		let data = try await browser.exportPaginatedPDFData(paperSize: a4)
		return try #require(PDFDocument(data: data), "the export produced no readable PDF")
	}

	/// Forced breaks are the reason this path exists at all: `exportPDFData`
	/// would emit one continuous page regardless of the CSS.
	@available(iOS 16.0, *)
	@Test("Forced page breaks are honoured", .timeLimit(.minutes(1)))
	func forcedPageBreaks() async throws {
		let html = """
		<html><head><style>h1 { page-break-before: always; }</style></head>
		<body>
		<h1>Alpha</h1><p>First.</p>
		<h1>Beta</h1><p>Second.</p>
		<h1>Gamma</h1><p>Third.</p>
		</body></html>
		"""
		// Four, not three: the rule fires on the first `h1` too, so the break
		// before it opens a page of its own. Both platforms agree on that — which
		// is the parity claim, since this same number is asserted on each.
		#expect(try await paginate(html).pageCount == 4)
	}

	/// The same document without the rule stays on one page, so the count above
	/// is the CSS being honoured rather than the content simply overflowing.
	@available(iOS 16.0, *)
	@Test("Without the rule the same content is a single page", .timeLimit(.minutes(1)))
	func withoutForcedBreaks() async throws {
		let html = """
		<html><body>
		<h1>Alpha</h1><p>First.</p>
		<h1>Beta</h1><p>Second.</p>
		<h1>Gamma</h1><p>Third.</p>
		</body></html>
		"""
		#expect(try await paginate(html).pageCount == 1)
	}

	/// Natural overflow paginates too — measured at 7 pages on both macOS and the
	/// iOS Simulator. The assertion stays loose because that number rides on
	/// default text metrics, which move between OS releases; the parity claim is
	/// carried by the forced-break case above, where the layout is pinned by CSS.
	@available(iOS 16.0, *)
	@Test("Content that overflows the page is split", .timeLimit(.minutes(2)))
	func naturalOverflow() async throws {
		let paragraphs = (1 ... 200).map { "<p>Paragraph number \($0) of the overflow fixture.</p>" }.joined()
		let document = try await paginate("<html><body>\(paragraphs)</body></html>")
		#expect(document.pageCount > 1)
		// The first page must carry real content — a paginator that emits blank
		// pages would still satisfy a bare count check.
		#expect(document.page(at: 0)?.string?.contains("Paragraph number 1") == true)
	}
}
#endif
