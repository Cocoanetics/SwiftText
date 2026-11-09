//  PageMarginTests.swift
//  SwiftTextRenderTests
//
//  CSS Paged Media: the `@page` margin shorthand (one to four values) and the
//  `margin-top` ... `margin-left` longhands set each side of the page box.

import Testing
import Foundation
@testable import SwiftTextRender

@Suite("Page margins")
struct PageMarginTests {

	/// The first page's content area as (left, top, right, bottom) margins in
	/// CSS pixels, read from the content clip rectangle. The document is long
	/// enough to fill the first page, so the clip is the content box up to the
	/// last line that fits.
	private func margins(css: String) async throws -> (left: Double, top: Double, right: Double, bottom: Double) {
		let paragraph = "<p>" + String(repeating: "Dies ist ein Satz mit etwas Text. ", count: 20) + "</p>"
		let html = String(repeating: paragraph, count: 40)
		let data = try await HTMLRenderer.renderPDF(html: html, css: [css],
		                                            options: RenderOptions(compressStreams: false, imageLoader: nil))
		let text = String(decoding: data, as: UTF8.self)
		let match = try #require(text.firstMatch(of: try Regex(#"([0-9.]+) ([0-9.]+) ([0-9.]+) ([0-9.]+) re"#)))
		let numbers = (1...4).compactMap { match.output[$0].substring.flatMap { Double($0) } }
		try #require(numbers.count == 4)
		let (x, y, width, height) = (numbers[0], numbers[1], numbers[2], numbers[3])
		return (x, 1056 - y - height, 816 - x - width, y)
	}

	private func expect(_ actual: (left: Double, top: Double, right: Double, bottom: Double),
	                    top: Double, right: Double, bottom: Double, left: Double) {
		#expect(abs(actual.top - top) < 0.1)
		#expect(abs(actual.right - right) < 0.1)
		// The last line that fits ends short of the margin by less than one line.
		#expect(actual.bottom >= bottom - 0.1 && actual.bottom < bottom + 30)
		#expect(abs(actual.left - left) < 0.1)
	}

	@Test("One value applies to all four sides")
	func oneValue() async throws {
		expect(try await margins(css: "@page { margin: 40px; }"), top: 40, right: 40, bottom: 40, left: 40)
	}

	@Test("Two values are vertical and horizontal")
	func twoValues() async throws {
		expect(try await margins(css: "@page { margin: 20px 60px; }"), top: 20, right: 60, bottom: 20, left: 60)
	}

	@Test("Three values are top, horizontal and bottom")
	func threeValues() async throws {
		expect(try await margins(css: "@page { margin: 20px 60px 40px; }"), top: 20, right: 60, bottom: 40, left: 60)
	}

	@Test("Four values are top, right, bottom, left")
	func fourValues() async throws {
		expect(try await margins(css: "@page { margin: 20px 60px 80px 40px; }"), top: 20, right: 60, bottom: 80, left: 40)
	}

	@Test("Longhands set their own side")
	func longhands() async throws {
		let css = "@page { margin: 30px; margin-top: 10px; margin-right: 50px; margin-bottom: 70px; margin-left: 90px; }"
		expect(try await margins(css: css), top: 10, right: 50, bottom: 70, left: 90)
	}
}
