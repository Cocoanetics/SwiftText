//
//  FragmentSeparatorTests.swift
//  SwiftTextOCRTests
//

import Foundation
import Testing

@testable import SwiftTextOCR

/// A line is split into fragments for two different reasons, and rejoining
/// them has to tell the two apart: a structural gap between table columns keeps
/// its tab, while the words the OCR reader separates to give each its own
/// bounds rejoin with the space that stood between them.
struct FragmentSeparatorTests {
	@Test("Words the reader split apart rejoin with a space")
	func adjoiningWordsRejoinWithASpace() {
		// The OCR word splitter cuts at the midpoint of the gap, so the pieces
		// it produces meet exactly.
		let line = TextLine(fragments: [
			fragment("Zweite", x: 0, width: 50),
			fragment("Ebene", x: 50, width: 40)
		])
		#expect(line.combinedText == "Zweite Ebene")
	}

	@Test("A gap too wide for a word space stays a tab")
	func wideGapStaysATab() {
		let line = TextLine(fragments: [
			fragment("Artikel", x: 0, width: 50),
			fragment("Preis", x: 200, width: 40)
		])
		#expect(line.combinedText == "Artikel\tPreis")
	}

	/// The threshold is relative to the type size, so the same layout at another
	/// scale reads the same way.
	@Test("The gap is judged against the type size", arguments: [
		(CGFloat(12), CGFloat(3), " "),
		(CGFloat(12), CGFloat(20), "\t"),
		(CGFloat(40), CGFloat(12), " "),
		(CGFloat(40), CGFloat(60), "\t")
	])
	func gapIsRelativeToTypeSize(_ testCase: (height: CGFloat, gap: CGFloat, separator: String)) {
		let line = TextLine(fragments: [
			fragment("A", x: 0, width: 30, height: testCase.height),
			fragment("B", x: 30 + testCase.gap, width: 30, height: testCase.height)
		])
		#expect(line.combinedText == "A\(testCase.separator)B")
	}

	@Test("Style runs are joined the same way as the text they cover")
	func styleRunsUseTheSameSeparator() {
		let style = TextStyle(fontSize: 11)
		let line = TextLine(fragments: [
			fragment("Zweite", x: 0, width: 50, runs: [StyleRun(text: "Zweite", style: style)]),
			fragment("Ebene", x: 50, width: 40, runs: [StyleRun(text: "Ebene", style: style)])
		])
		#expect(line.styleRuns.text == line.combinedText)
		#expect(line.styleRuns.text == "Zweite Ebene")
	}

	private func fragment(
		_ string: String, x: CGFloat, width: CGFloat, height: CGFloat = 12, runs: [StyleRun] = []
	) -> TextFragment {
		TextFragment(
			bounds: CGRect(x: x, y: 0, width: width, height: height),
			string: string,
			styleRuns: runs)
	}
}
