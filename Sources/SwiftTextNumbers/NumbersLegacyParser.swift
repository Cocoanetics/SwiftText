import Foundation
#if canImport(FoundationXML)
// On Linux, XMLParser/XMLParserDelegate live in FoundationXML, not Foundation.
import FoundationXML
#endif
import SwiftTextIWA

/// Reads the legacy iWork '09 Numbers format, whose content is a single `index.xml`
/// (the APXL-era schema) rather than `.iwa` objects — the Numbers counterpart to
/// `PagesLegacyParser`.
///
/// A table is `<sf:tabular-model>` → `<sf:grid sf:numcols sf:numrows>` →
/// `<sf:datasource>`, where the datasource is a row-major stream with one element per
/// grid cell: `<sf:t>` text (the string is in its `<sf:ct sfa:s>` child, absent for an
/// empty cell), `<sf:g>` a blank cell, and `<sf:f>` a formula (`<sf:fo sf:fs>`). Unlike
/// the modern binary format there are no tile buffers or decimal128 — values are plain
/// XML. The decoded grids map to the same `TSTTable` model the modern reader produces,
/// so all Markdown/HTML/JSON/TSV rendering is shared.
///
/// > Note: verified against real '09 text tables. The '09 format stores no reliably
/// > readable cached result for a formula cell, so a formula renders as its source text
/// > (e.g. `=SUM(A)`); numeric cells (`<sf:n>`) are decoded best-effort.
struct NumbersLegacyParser {
	func parseDocument(from data: Data) throws -> NumbersDocument {
		let extractor = LegacyTableExtractor()
		let parser = XMLParser(data: data)
		parser.delegate = extractor
		guard parser.parse() else {
			throw NumbersParserError.legacyXMLParsingFailed(parser.parserError)
		}
		let tables = extractor.tables
		return NumbersDocument(sheets: tables.isEmpty ? [] : [NumbersDocument.Sheet(name: nil, tables: tables)])
	}
}

/// Streams the `<sf:tabular-model>` grids out of a legacy `index.xml`, accumulating each
/// grid's cells in document (row-major) order and shaping them into a `TSTTable`.
private final class LegacyTableExtractor: NSObject, XMLParserDelegate {
	private(set) var tables: [TSTTable] = []

	private var columns = 0
	private var rows = 0
	private var cells: [String] = []
	private var elementStack: [String] = []
	private var inDatasource = false
	private var buildingCell = false
	private var currentCellValue = ""

	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
	            qualifiedName: String?, attributes: [String: String]) {
		switch elementName {
		case "sf:grid":
			columns = attributes["sf:numcols"].flatMap(Int.init) ?? 0
			rows = attributes["sf:numrows"].flatMap(Int.init) ?? 0
			cells = []
		case "sf:datasource":
			inDatasource = true
		case "sf:ct" where buildingCell:
			// The inline string of a <sf:t> text cell; absent => the cell is empty.
			if let string = attributes["sfa:s"] { currentCellValue = string }
		case "sf:fo" where buildingCell:
			// A formula cell's source text (the '09 format keeps no readable result).
			if let formula = attributes["sf:fs"] { currentCellValue = formula }
		default:
			// Any direct child of <sf:datasource> is a cell at the next grid position.
			if inDatasource, elementStack.last == "sf:datasource" {
				buildingCell = true
				// A numeric cell carries its value inline; decoded best-effort.
				currentCellValue = attributes["sf:v"] ?? attributes["sfa:number"] ?? ""
			}
		}
		elementStack.append(elementName)
	}

	func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
	            qualifiedName: String?) {
		elementStack.removeLast()
		// A cell closes when we pop back up to the datasource level.
		if buildingCell, inDatasource, elementStack.last == "sf:datasource" {
			cells.append(currentCellValue)
			buildingCell = false
			currentCellValue = ""
		}
		if elementName == "sf:datasource" {
			inDatasource = false
			if let table = makeTable() { tables.append(table) }
		}
	}

	/// Fills a `rows × columns` grid from the row-major cell stream. Cells beyond the
	/// stream (trailing empties the '09 writer omits) stay blank.
	private func makeTable() -> TSTTable? {
		guard rows > 0, columns > 0 else { return nil }
		var grid = Array(repeating: Array(repeating: "", count: columns), count: rows)
		for (index, value) in cells.enumerated() where index < rows * columns {
			grid[index / columns][index % columns] = value
		}
		// '09 cell styling isn't resolved here; lean on the implicit default — a column
		// whose body is purely numeric right-aligns, matching the modern reader's output.
		var alignments = Array(repeating: TSTTable.Alignment.left, count: columns)
		for column in 0..<columns {
			let body = grid.dropFirst().map { $0[column] }.filter { !$0.isEmpty }
			if !body.isEmpty, body.allSatisfy({ Double($0) != nil }) { alignments[column] = .right }
		}
		return TSTTable(cells: grid, columnAlignments: alignments)
	}
}
