//  NamedPageTests.swift
//  SwiftTextRenderTests
//
//  CSS Paged Media: `@page <name>` with `page: <name>`, and the `:first`,
//  `:left`, `:right` pseudo-classes. A named or pseudo rule must never be
//  applied to the whole document.

import Testing
import Foundation
@testable import SwiftTextRender

@Suite("Named pages")
struct NamedPageTests {

	/// Each page's `/MediaBox` size in points, read from the raw PDF bytes (page
	/// dictionaries are never inside a compressed stream).
	private func pageSizes(_ data: Data) throws -> [(width: Int, height: Int)] {
		let text = String(decoding: data, as: UTF8.self)
		let expression = try Regex(#"/MediaBox \[0 0 ([0-9.]+) ([0-9.]+)\]"#)
		return text.matches(of: expression).compactMap { match in
			guard let width = match.output[1].substring.flatMap({ Double($0) }),
			      let height = match.output[2].substring.flatMap({ Double($0) }) else { return nil }
			return (Int(width.rounded()), Int(height.rounded()))
		}
	}

	private let document = """
	<style>h1 { break-before: page; }</style>
	<h1>Eins</h1><p>Text eins.</p>
	<h1>Drei</h1>
	<div class="wide"><table><tr><td>A</td><td>B</td></tr><tr><td>1</td><td>2</td></tr></table></div>
	<h1>Vier</h1><p>Text vier.</p>
	"""

	private func render(css: String) async throws -> [(width: Int, height: Int)] {
		let data = try await HTMLRenderer.renderPDF(html: document, css: [css], options: RenderOptions(imageLoader: nil))
		return try pageSizes(data)
	}

	@Test("A named page puts only its block on the landscape page")
	func namedPageSize() async throws {
		let sizes = try await render(css: "@page wide { size: A4 landscape; } .wide { page: wide; }")
		#expect(sizes.map(\.width) == [612, 612, 842, 612])
		#expect(sizes.map(\.height) == [792, 792, 595, 792])
	}

	@Test("A named @page rule without a block using it changes nothing")
	func unusedNamedPage() async throws {
		let sizes = try await render(css: "@page wide { size: A4 landscape; }")
		#expect(sizes.allSatisfy { $0.width == 612 && $0.height == 792 })
	}

	@Test("@page :first { size } resizes the first page only")
	func firstPageSize() async throws {
		let sizes = try await render(css: "@page :first { size: A5; }")
		#expect(sizes.count == 3)
		#expect(sizes.map(\.width) == [420, 612, 612])
		#expect(sizes.map(\.height) == [595, 792, 792])
	}

	@Test("a lone orientation in @page :first turns the first page")
	func firstPageOrientation() async throws {
		let sizes = try await render(css: "@page :first { size: landscape; }")
		#expect(sizes.map(\.width) == [792, 612, 612])
		#expect(sizes.map(\.height) == [612, 792, 792])
	}

	@Test("@page :left / :right { size } resize the pages of that side only")
	func sideSizes() async throws {
		let sizes = try await render(css: "@page :left { size: A5; }")
		#expect(sizes.count == 3)
		#expect(sizes.map(\.width) == [612, 420, 612])
		let right = try await render(css: "@page :right { size: A5 landscape; }")
		#expect(right.map(\.width) == [595, 612, 595])
		#expect(right.map(\.height) == [420, 792, 420])
	}

	@Test("A named page without a size falls back to the document size")
	func namedPageWithoutSize() async throws {
		let sizes = try await render(css: ".wide { page: plain; }")
		#expect(sizes.count == 4)
		#expect(sizes.allSatisfy { $0.width == 612 && $0.height == 792 })
	}

	@Test("@page :left / :right shift the content by their own left margin")
	func mirroredMargins() async throws {
		let html = "<style>h1 { break-before: page; }</style><h1>Eins</h1><h1>Zwei</h1>"
		let css = "@page { margin: 20px; } @page :right { margin-left: 30px; } @page :left { margin-left: 10px; }"
		let data = try await HTMLRenderer.renderPDF(
			html: html, css: [css], options: RenderOptions(compressStreams: false, imageLoader: nil))
		let text = String(decoding: data, as: UTF8.self)
		// The base matrix carries the horizontal shift: +10px = 7.5pt, -10px = -7.5pt.
		#expect(text.contains("0.75 0 0 0.75 7.5 0 cm"))
		#expect(text.contains("0.75 0 0 0.75 -7.5 0 cm"))
	}

	@Test("Adjacent blocks with the same page name share one run")
	func adjacentSameName() async throws {
		let html = "<div style=\"page: wide\"><p>A</p></div><div style=\"page: wide\"><p>B</p></div>"
		let data = try await HTMLRenderer.renderPDF(html: html, css: ["@page wide { size: A4 landscape; }"],
		                                            options: RenderOptions(imageLoader: nil))
		#expect(try pageSizes(data).count == 1)
	}

	@Test(":first outranks :right on the first page regardless of source order")
	func pseudoSpecificity() async throws {
		let css = "@page { margin: 20px; } @page :first { margin-left: 30px; } @page :right { margin-left: 10px; }"
		let data = try await HTMLRenderer.renderPDF(html: "<p>A</p>", css: [css],
		                                            options: RenderOptions(compressStreams: false, imageLoader: nil))
		#expect(String(decoding: data, as: UTF8.self).contains("0.75 0 0 0.75 7.5 0 cm"))
	}
}
