//  CSSColorTests.swift
//  SwiftTextCSSTests

import Testing
@testable import SwiftTextCSS

@Suite("CSS Color")
struct CSSColorTests {

	private func rgba(_ input: String) -> RGBA? {
		if case .rgba(let value) = parseColor(input) { return value }
		return nil
	}

	@Test("Named keywords")
	func keywords() {
		#expect(parseColor("red") == .rgba(RGBA(1, 0, 0, 1)))
		#expect(parseColor("white") == .rgba(RGBA(1, 1, 1, 1)))
		#expect(parseColor("transparent") == .rgba(RGBA(0, 0, 0, 0)))
		#expect(parseColor("currentColor") == .currentColor)
		#expect(parseColor("CurrentColor") == .currentColor) // case-insensitive
		#expect(parseColor("RebeccaPurple") == nil) // not in CSS3 table
	}

	@Test("Hex colors")
	func hex() {
		#expect(parseColor("#fff") == .rgba(RGBA(1, 1, 1, 1)))
		#expect(parseColor("#ff0000") == .rgba(RGBA(1, 0, 0, 1)))
		#expect(parseColor("#000") == .rgba(RGBA(0, 0, 0, 1)))
		let alpha = rgba("#00ff0080")
		#expect(alpha?.green == 1)
		#expect((alpha.map { abs($0.alpha - 128.0 / 255.0) < 1e-9 }) == true)
	}

	@Test("rgb() and rgba()")
	func rgbFunctions() {
		#expect(parseColor("rgb(255, 0, 0)") == .rgba(RGBA(1, 0, 0, 1)))
		#expect(parseColor("rgb(100%, 0%, 0%)") == .rgba(RGBA(1, 0, 0, 1)))
		let half = rgba("rgba(0, 0, 0, 0.5)")
		#expect(half?.alpha == 0.5)
		#expect(parseColor("rgb(255, 0)") == nil) // wrong arg count
	}

	@Test("hsl() colors")
	func hslFunctions() {
		#expect(parseColor("hsl(120, 100%, 50%)") == .rgba(RGBA(0, 1, 0, 1)))
		#expect(parseColor("hsl(0, 100%, 50%)") == .rgba(RGBA(1, 0, 0, 1)))
	}

	@Test("Invalid colors return nil")
	func invalid() {
		#expect(parseColor("bogus") == nil)
		#expect(parseColor("12px") == nil)
		#expect(parseColor("") == nil)
		#expect(parseColor("red blue") == nil)
	}
}
