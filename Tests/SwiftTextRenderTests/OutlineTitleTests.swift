import Testing
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
@testable import SwiftTextRender

@Suite("Outline titles")
struct OutlineTitleTests {
	@Test("Outline title of a heading wrapped at a hyphen is the source text")
	func outlineTitleIgnoresWrap() async throws {
		let title = "Wie Sie Ihre Parkinson-Erkrankung bremsen können"
		let html = "<style>h1 { font-size: 24pt; width: 190pt }</style><h1>\(title)</h1><p>Body.</p>"
		let data = try await HTMLRenderer.renderPDF(html: html)
		#if canImport(PDFKit)
		let document = try #require(PDFDocument(data: data))
		let outline = try #require(document.outlineRoot)
		#expect(outline.child(at: 0)?.label == title)
		#endif
	}

	@Test("Outline title keeps a space at a <br> line break")
	func outlineTitleBreak() async throws {
		let data = try await HTMLRenderer.renderPDF(html: "<h1>Chapter 1<br>The Beginning</h1><p>Body.</p>")
		#if canImport(PDFKit)
		let document = try #require(PDFDocument(data: data))
		let outline = try #require(document.outlineRoot)
		#expect(outline.child(at: 0)?.label == "Chapter 1 The Beginning")
		#endif
	}
}
