//  TableColumnWidthsTests.swift
//  SwiftTextRenderTests

import Testing
@testable import SwiftTextRender

@Suite("Table column widths")
struct TableColumnWidthsTests {
	@Test("Shrinkage is distributed over max-content slack")
	func distributesShrinkageOverMaxContentSlack() {
		let widths = TableColumnWidths.fit(
			preferred: [200, 100, 60, 300],
			minimum: [100, 50, 50, 200],
			to: 450)

		let expected = [100 + 50.0 / 260 * 100,
		                50 + 50.0 / 260 * 50,
		                50 + 50.0 / 260 * 10,
		                200 + 50.0 / 260 * 100]
		#expect(widths.indices.allSatisfy { abs(widths[$0] - expected[$0]) < 0.001 })
	}

	@Test("An oversized minimum is absorbed by the widest column")
	func oversizedMinimumShrinksWidestColumn() {
		let widths = TableColumnWidths.fit(
			preferred: [202.9, 111.6, 58.9, 570],
			minimum: [120, 64, 57, 252],
			to: 481)

		#expect(widths == [120, 64, 57, 240])
	}

	@Test("Oversized minimums cap the widest column group")
	func oversizedMinimumCapsWidestColumns() {
		let widths = TableColumnWidths.fit(
			preferred: [150, 140, 40],
			minimum: [120, 100, 30],
			to: 190)

		#expect(widths == [80, 80, 30])
	}
}
