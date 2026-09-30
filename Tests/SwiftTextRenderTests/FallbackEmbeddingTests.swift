//  FallbackEmbeddingTests.swift
//  SwiftTextRenderTests
//
//  Text set in a system fallback font, checked in the PDF that is written:
//  how large the embedded font program is, and where the runs are painted.

import Foundation
import Testing
@testable import SwiftTextRender

@Suite("Fallback font embedding")
struct FallbackEmbeddingTests {
	/// macOS's CJK fallback: CFF outlines inside a 23 MB collection.
	static var hiraginoAvailable: Bool {
		FileManager.default.fileExists(atPath: "/System/Library/Fonts/Hiragino Sans GB.ttc")
	}

	private func render(_ html: String, compress: Bool = true) async throws -> Data {
		var options = RenderOptions()
		options.compressStreams = compress
		return try await HTMLRenderer.renderPDF(html: html, options: options)
	}

	/// 2.2.0 embedded the whole collection: 22.8 MB for one line of Japanese.
	@Test("A CFF fallback font is embedded as a subset", .enabled(if: hiraginoAvailable))
	func cffFallbackIsSubset() async throws {
		let pdf = try await render("<p>日本語のテキスト</p>")
		#expect(pdf.count < 300_000)
		let text = String(decoding: pdf, as: UTF8.self)
		#expect(text.contains("/FontFile3"))
	}

	/// 2.2.0 painted the comma 4 pt (a space) past the end of the run before
	/// it whenever the paragraph also held right-to-left text.
	@Test("Punctuation after a fallback run is painted where the run ends", .enabled(if: hiraginoAvailable))
	func noGapAfterFallbackRun() async throws {
		let pdf = try await render("<p>テキスト, עברית</p>", compress: false)
		let origins = String(decoding: pdf, as: UTF8.self)
			.split(separator: "\n")
			.filter { $0.hasSuffix(" Td") }
			.compactMap { Double($0.split(separator: " ")[0]) }
		try #require(origins.count == 3)
		// Four full-width katakana at the default 16 px.
		#expect(origins[1] - origins[0] == 64)
	}
}
