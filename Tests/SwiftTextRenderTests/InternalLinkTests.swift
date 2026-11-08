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

	@Test("An anchor exactly on a page boundary belongs to the following page")
	func boundaryAnchorIsOnFollowingPage() async throws {
		let html = """
		<div style="margin: 0">first</div>
		<div id="second" style="break-before: page; margin: 0">text</div>
		"""
		let result = try await HTMLRenderer.renderPDFWithAnchors(html: html, options: Self.options)
		#expect(result.anchorPages["second"] == 1)
	}
}
