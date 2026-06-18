import XCTest
@testable import SwiftTextPages

/// Exercises the Numbers reader against `Sample.numbers`, a small fixture authored in
/// Numbers with a header row, plain values, and two formula cells (`=SUM(C2:C3)` and
/// `=NOW()`). It pins the behaviours the reader is built on: reading *frozen* formula
/// results without a calculation engine, and reading cells that follow an empty gap.
final class NumbersFileTests: XCTestCase {
	private func fixture() throws -> NumbersFile {
		let url = try XCTUnwrap(Bundle.module.url(forResource: "Sample", withExtension: "numbers"))
		return try NumbersFile(url: url)
	}

	func testReadsSheetAndTable() throws {
		let document = try fixture().document
		XCTAssertEqual(document.sheets.count, 1)
		let sheet = try XCTUnwrap(document.sheets.first)
		XCTAssertEqual(sheet.name, "Sheet 1")
		XCTAssertEqual(sheet.tables.count, 1)
	}

	func testDecodesValuesIncludingFrozenFormulaResults() throws {
		let table = try XCTUnwrap(fixture().document.allTables.first?.trimmedToUsedRange())

		// Header + plain values.
		XCTAssertEqual(table.cells[0], ["Item", "Qty", "Price"])
		XCTAssertEqual(table.cells[1], ["Widget", "3", "9.99"])
		XCTAssertEqual(table.cells[2], ["Gadget", "10", "2.5"])

		// `=SUM(C2:C3)` is read as its frozen result, with no formula engine. It sits in
		// column C of a row whose column B is empty — so reading it at all also proves the
		// tile decoder does not stop at the first empty-cell (`0xFFFF`) gap.
		XCTAssertEqual(table.cells[3][0], "Total")
		XCTAssertEqual(table.cells[3][2], "12.49")

		// `=NOW()` is frozen as a date cell (its exact instant depends on when the fixture
		// was authored, so match the shape rather than a literal timestamp).
		let nowCell = table.cells[4][1]
		XCTAssertTrue(
			nowCell.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression) != nil,
			"expected a frozen date in B5, got \(nowCell)"
		)
	}

	func testNumericColumnsRightAlign() throws {
		let table = try XCTUnwrap(fixture().document.allTables.first?.trimmedToUsedRange())
		XCTAssertEqual(table.columnAlignments[0], .left)   // Item (text)
		XCTAssertEqual(table.columnAlignments[1], .right)  // Qty (numeric)
		XCTAssertEqual(table.columnAlignments[2], .right)  // Price (numeric)
	}

	func testMarkdownRendersGFMTable() throws {
		let markdown = try fixture().markdown()
		XCTAssertTrue(markdown.contains("| Item | Qty | Price |"))
		XCTAssertTrue(markdown.contains("| --- | --: | --: |"))
		XCTAssertTrue(markdown.contains("| Widget | 3 | 9.99 |"))
		XCTAssertTrue(markdown.contains("| Total |  | 12.49 |"))
	}

	func testHTMLRendersTable() throws {
		let html = try fixture().html()
		XCTAssertTrue(html.contains("<table>"))
		XCTAssertTrue(html.contains("<th>Item</th>"))
		XCTAssertTrue(html.contains("<td style=\"text-align:right\">12.49</td>"))
	}

	func testJSONRoundTripsThroughCodableModel() throws {
		let jsonString = try fixture().json()
		let decoded = try JSONDecoder().decode(NumbersDocument.self, from: Data(jsonString.utf8))
		XCTAssertEqual(decoded.sheets.first?.name, "Sheet 1")
		let table = try XCTUnwrap(decoded.allTables.first)
		XCTAssertEqual(table.cells[0], ["Item", "Qty", "Price"])
		XCTAssertEqual(table.cells[3][2], "12.49")
		XCTAssertEqual(table.columnAlignments, [.left, .right, .right])
	}
}
