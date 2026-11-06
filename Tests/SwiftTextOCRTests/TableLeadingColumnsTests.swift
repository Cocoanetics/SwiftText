//
//  TableLeadingColumnsTests.swift
//  SwiftTextOCRTests
//

import Foundation
import Testing

@testable import SwiftTextOCR

/// A lab report sets each row as one page line (name, value, unit, range) with
/// a bar graphic beside it. When the segmenter's table covers only the unit and
/// range columns, the rows' leading cells must still reach the Markdown.
struct TableLeadingColumnsTests {
	private let pageSize = CGSize(width: 1000, height: 800)

	private let rows: [(name: String, value: String, unit: String, range: String)] = [
		("Lymphocyten Absolut", "1,68", "G/I", "1.00 - 4.00"),
		("Monocyten", "9,7", "%", "2.0 - 10.0"),
		("Monocyten Absolut", "0,72", "G/I", "0.00 - 1.20")
	]

	@Test("Cells left of a partial table are not dropped from the Markdown")
	func leadingColumnsSurvive() {
		var lines = [pageLine([("DIFFERENTIAL-BLUTBILD", 50, 150)], y: 100)]
		var tableRows = [[NormalizedDocumentBlock.NormalizedTableCell]]()
		var cellRows = [[DocumentBlock.Table.Cell]]()

		for (index, row) in rows.enumerated() {
			let y = CGFloat(150 + index * 30)
			lines.append(pageLine([(row.name, 50, 250), (row.value, 330, 50), (row.unit, 600, 40), (row.range, 700, 120)], y: y))
			let cells = [(row.unit, CGFloat(600), CGFloat(40)), (row.range, CGFloat(700), CGFloat(120))]
				.enumerated().map { column, entry -> DocumentBlock.Table.Cell in
					let bounds = CGRect(x: entry.1, y: y, width: entry.2, height: 20)
					return DocumentBlock.Table.Cell(
						rowRange: index...index, columnRange: column...column,
						text: entry.0, bounds: bounds,
						lines: [DocumentBlock.TextLine(text: entry.0, bounds: bounds)])
				}
			cellRows.append(cells)
			tableRows.append(cells.map { .init(normalizedBounds: normalized($0.bounds), cell: $0) })
		}

		let tableBounds = CGRect(x: 600, y: 150, width: 220, height: 90)
		let table = NormalizedDocumentBlock(
			block: DocumentBlock(bounds: tableBounds, kind: .table(.init(rows: cellRows))),
			normalizedBounds: normalized(tableBounds),
			tableRows: tableRows)
		let captionBounds = CGRect(x: 50, y: 100, width: 150, height: 20)
		let semantics = DocumentSemantics(
			referenceSize: pageSize,
			blocks: [
				NormalizedDocumentBlock(
					block: DocumentBlock(bounds: captionBounds, kind: .paragraph(.init(
						text: "DIFFERENTIAL-BLUTBILD",
						lines: [.init(text: "DIFFERENTIAL-BLUTBILD", bounds: captionBounds)]))),
					normalizedBounds: normalized(captionBounds)),
				table
			],
			images: [])

		let blocks = TextLineSemanticComposer.composeBlocks(
			from: lines, semantics: semantics, layoutSize: pageSize)
		let markdown = DocumentBlockMarkdownRenderer.markdown(from: blocks)

		for row in rows {
			#expect(markdown.contains(row.name), "missing \(row.name) in:\n\(markdown)")
			#expect(markdown.contains(row.value), "missing \(row.value) in:\n\(markdown)")
			#expect(markdown.contains(row.range))
		}
	}

	/// A leading value that equals a retained cell, or sits inside one, is still
	/// a cell the Markdown lacks.
	@Test("A leading fragment equal to or inside a retained cell is still restored")
	func repeatedAndContainedFragmentsAreRestored() {
		let line = pageLine([("Wert", 50, 100), ("1.00", 200, 50), ("%", 300, 20), ("1.00 - 4.00", 400, 100)], y: 150)
		let cellBounds = [CGRect(x: 300, y: 150, width: 20, height: 20), CGRect(x: 400, y: 150, width: 100, height: 20)]
		let cells = [("%", 0), ("1.00 - 4.00", 1)].map { text, column in
			DocumentBlock.Table.Cell(
				rowRange: 0...0, columnRange: column...column, text: text, bounds: cellBounds[column],
				lines: [DocumentBlock.TextLine(text: text, bounds: cellBounds[column])])
		}
		let tableBounds = cellBounds[0].union(cellBounds[1])
		let heading = CGRect(x: 50, y: 50, width: 100, height: 20)
		let semantics = DocumentSemantics(
			referenceSize: pageSize,
			blocks: [
				NormalizedDocumentBlock(
					block: DocumentBlock(bounds: heading, kind: .paragraph(.init(
						text: "Wert", lines: [.init(text: "Wert", bounds: heading)]))),
					normalizedBounds: normalized(heading)),
				NormalizedDocumentBlock(
					block: DocumentBlock(bounds: tableBounds, kind: .table(.init(rows: [cells]))),
					normalizedBounds: normalized(tableBounds),
					tableRows: [cells.enumerated().map { .init(normalizedBounds: normalized(cellBounds[$0.offset]), cell: $0.element) }])
			],
			images: [])
		let blocks = TextLineSemanticComposer.composeBlocks(
			from: [pageLine([("Wert", 50, 100)], y: 50), line], semantics: semantics, layoutSize: pageSize)
		let markdown = DocumentBlockMarkdownRenderer.markdown(from: blocks)

		#expect(markdown.components(separatedBy: "Wert").count - 1 == 2, "\(markdown)")
		#expect(markdown.contains("1.00 Wert") || markdown.contains("Wert 1.00"), "\(markdown)")
	}

	private func pageLine(_ words: [(String, CGFloat, CGFloat)], y: CGFloat) -> TextLine {
		TextLine(fragments: words.map { text, x, width in
			TextFragment(bounds: CGRect(x: x, y: y, width: width, height: 20), string: text, styleRuns: [])
		})
	}

	private func normalized(_ rect: CGRect) -> NormalizedRect {
		NormalizedRect(
			minX: rect.minX / pageSize.width,
			minY: rect.minY / pageSize.height,
			width: rect.width / pageSize.width,
			height: rect.height / pageSize.height)
	}
}
