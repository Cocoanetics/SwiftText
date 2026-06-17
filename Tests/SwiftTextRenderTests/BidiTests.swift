//  BidiTests.swift
//  SwiftTextRenderTests

import Testing
@testable import SwiftTextRender

@Suite("Bidi (UAX #9)")
struct BidiTests {

	private func order(_ string: String, _ direction: BidiDirection) -> [Int] {
		let scalars = Array(string.unicodeScalars)
		return Bidi.visualOrder(levels: Bidi.levels(for: scalars, baseDirection: direction))
	}

	@Test("Pure LTR text keeps its order")
	func ltr() {
		let scalars = Array("abc".unicodeScalars)
		#expect(Bidi.levels(for: scalars, baseDirection: .leftToRight) == [0, 0, 0])
		#expect(order("abc", .leftToRight) == [0, 1, 2])
	}

	@Test("Hebrew in an LTR paragraph is reversed")
	func hebrewInLTR() {
		// א ב ג  (U+05D0..05D2)
		let scalars = Array("\u{05D0}\u{05D1}\u{05D2}".unicodeScalars)
		#expect(Bidi.levels(for: scalars, baseDirection: .leftToRight) == [1, 1, 1])
		#expect(order("\u{05D0}\u{05D1}\u{05D2}", .leftToRight) == [2, 1, 0])
	}

	@Test("Latin then Hebrew: the Hebrew run flips, Latin stays")
	func mixed() {
		// "ab גד"  → indices 0:a 1:b 2:space 3:ג 4:ד
		#expect(order("ab \u{05D2}\u{05D3}", .leftToRight) == [0, 1, 2, 4, 3])
	}

	@Test("Numbers stay left-to-right inside RTL text")
	func numbersInRTL() {
		// "א25ב" → indices 0:א 1:2 2:5 3:ב, base RTL
		let scalars = Array("\u{05D0}25\u{05D1}".unicodeScalars)
		#expect(Bidi.levels(for: scalars, baseDirection: .rightToLeft) == [1, 2, 2, 1])
		// Visual L→R: ב 2 5 א — the number reads "25", the letters flip.
		#expect(order("\u{05D0}25\u{05D1}", .rightToLeft) == [3, 1, 2, 0])
	}

	@Test("RTL scalar detection")
	func rtlDetection() {
		#expect(Bidi.isRTLScalar("\u{05D0}"))      // Hebrew alef
		#expect(Bidi.isRTLScalar("\u{0627}"))      // Arabic alef
		#expect(!Bidi.isRTLScalar("a"))
		#expect(!Bidi.isRTLScalar("5"))
	}
}
