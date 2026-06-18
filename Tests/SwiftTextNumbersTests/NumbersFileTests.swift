import Foundation
import Testing

import SwiftTextIWA
import SwiftTextNumbers

/// Exercises the Numbers reader against `Sample.numbers`, a small fixture authored in
/// Numbers with a header row, plain values, and two formula cells (`=SUM(C2:C3)` and
/// `=NOW()`). It pins the behaviours the reader is built on: reading *frozen* formula
/// results without a calculation engine, and reading cells that follow an empty gap.
@Suite("Numbers reader")
struct NumbersFileTests {
	private func fixture() throws -> NumbersFile {
		let url = try #require(Bundle.module.url(forResource: "Sample", withExtension: "numbers"))
		return try NumbersFile(url: url)
	}

	@Test("Reads the sheet name and its single table")
	func readsSheetAndTable() throws {
		let document = try fixture().document
		#expect(document.sheets.count == 1)
		let sheet = try #require(document.sheets.first)
		#expect(sheet.name == "Sheet 1")
		#expect(sheet.tables.count == 1)
	}

	@Test("Decodes values, including frozen formula results")
	func decodesValuesIncludingFrozenFormulaResults() throws {
		let table = try #require(fixture().document.allTables.first?.trimmedToUsedRange())

		// Header + plain values.
		#expect(table.cells[0] == ["Item", "Qty", "Price"])
		#expect(table.cells[1] == ["Widget", "3", "9.99"])
		#expect(table.cells[2] == ["Gadget", "10", "2.5"])

		// `=SUM(C2:C3)` is read as its frozen result, with no formula engine. It sits in
		// column C of a row whose column B is empty — so reading it at all also proves the
		// tile decoder does not stop at the first empty-cell (`0xFFFF`) gap.
		#expect(table.cells[3][0] == "Total")
		#expect(table.cells[3][2] == "12.49")

		// `=NOW()` is frozen as a date cell (its exact instant depends on when the fixture
		// was authored, so match the shape rather than a literal timestamp).
		let nowCell = table.cells[4][1]
		#expect(
			nowCell.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression) != nil,
			"expected a frozen date in B5, got \(nowCell)"
		)
	}

	@Test("Numeric columns right-align")
	func numericColumnsRightAlign() throws {
		let table = try #require(fixture().document.allTables.first?.trimmedToUsedRange())
		#expect(table.columnAlignments[0] == .left)   // Item (text)
		#expect(table.columnAlignments[1] == .right)  // Qty (numeric)
		#expect(table.columnAlignments[2] == .right)  // Price (numeric)
	}

	@Test("Markdown renders a GFM table")
	func markdownRendersGFMTable() throws {
		let markdown = try fixture().markdown()
		#expect(markdown.contains("| Item | Qty | Price |"))
		#expect(markdown.contains("| --- | --: | --: |"))
		#expect(markdown.contains("| Widget | 3 | 9.99 |"))
		#expect(markdown.contains("| Total |  | 12.49 |"))
	}

	@Test("HTML renders a table")
	func htmlRendersTable() throws {
		let html = try fixture().html()
		#expect(html.contains("<table>"))
		#expect(html.contains("<th>Item</th>"))
		#expect(html.contains("<td style=\"text-align:right\">12.49</td>"))
	}

	@Test("JSON round-trips through the Codable model")
	func jsonRoundTripsThroughCodableModel() throws {
		let jsonString = try fixture().json()
		let decoded = try JSONDecoder().decode(NumbersDocument.self, from: Data(jsonString.utf8))
		#expect(decoded.sheets.first?.name == "Sheet 1")
		let table = try #require(decoded.allTables.first)
		#expect(table.cells[0] == ["Item", "Qty", "Price"])
		#expect(table.cells[3][2] == "12.49")
		#expect(table.columnAlignments == [.left, .right, .right])
	}

	@Test("Reads cells beyond the first tile (rows past tileSize)")
	func readsCellsAcrossMultipleTiles() throws {
		// MultiTile.numbers is a 300-row table; with the standard 256-row tiles, A260 and
		// A300 live in the second tile. A single-tile reader would drop them.
		let url = try #require(Bundle.module.url(forResource: "MultiTile", withExtension: "numbers"))
		let table = try #require(NumbersFile(url: url).document.allTables.first)
		#expect(table.rows == 300)
		#expect(table.cells[0][0] == "Idx")
		#expect(table.cells[259][0] == "row260")
		#expect(table.cells[299][0] == "lastrow")
	}
}
