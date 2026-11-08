//  InternalLinkTests.swift
//  SwiftTextRenderTests

import Testing
import Foundation
@testable import SwiftTextRender

@Suite("Internal links")
struct InternalLinkTests {

	private static var options: RenderOptions {
		RenderOptions(pageWidthPx: 400, pageHeightPx: 300, pageMarginPx: 20, compressStreams: false)
	}

	private static let html = """
	<p><a href="#target">jump</a> <a href="#missing">nowhere</a> <a href="https://example.com/x">out</a></p>
	<div style="break-after: page"></div>
	<p>filler</p>
	<h2 id="target" style="break-before: page">Target</h2>
	"""

	@Test("A #fragment link becomes a GoTo to the target's page")
	func fragmentBecomesGoTo() async throws {
		let result = try await HTMLRenderer.renderPDFWithAnchors(html: Self.html, options: Self.options)
		let text = String(decoding: result.data, as: UTF8.self)
		#expect(result.anchorPages["target"] == 1)
		#expect(!text.contains("/URI (#target)"))
		#expect(text.contains("/S /GoTo"))
		// The unknown fragment and the external URL stay URI actions.
		#expect(text.contains("/URI (#missing)"))
		#expect(text.contains("/URI (https://example.com/x)"))
	}

	@Test("renderPDF still returns the PDF bytes")
	func wrapperMatches() async throws {
		let data = try await HTMLRenderer.renderPDF(html: Self.html, options: Self.options)
		#expect(data.starts(with: Data("%PDF".utf8)))
	}
}
