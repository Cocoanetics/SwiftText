//
//  TextLineSemanticComposerStyleTests.swift
//  SwiftTextOCRTests
//

import Foundation
import Testing

@testable import SwiftTextOCR

struct TextLineSemanticComposerStyleTests {
	private let pageSize = CGSize(width: 600, height: 800)

	@Test("An unmatched standalone text-layer line keeps its heading style")
	func standaloneLineKeepsStyleRuns() {
		let titleBounds = CGRect(x: 50, y: 20, width: 200, height: 20)
		let bodyBounds = CGRect(x: 50, y: 100, width: 400, height: 20)
		let lines = [
			textLine("Title", bounds: titleBounds, size: 22, bold: true),
			textLine(
				"A much longer body line establishes the document body size.",
				bounds: bodyBounds,
				size: 11)
		]
		let semantics = semanticsForParagraph(text: lines[1].combinedText, bounds: bodyBounds)

		let blocks = TextLineSemanticComposer.composeBlocks(
			from: lines, semantics: semantics, layoutSize: pageSize)
		let markdown = DocumentBlockMarkdownRenderer.markdown(from: blocks)

		#expect(markdown.contains("# Title"))
	}

	@Test("Typography-derived heading remains separate during semantic composition")
	func inferredHeadingIsAMergeBarrier() {
		let titleBounds = CGRect(x: 50, y: 20, width: 200, height: 20)
		let bodyBounds = CGRect(x: 50, y: 43, width: 400, height: 20)
		let title = textLine("Title", bounds: titleBounds, size: 22, bold: true)
		let body = textLine(
			"A much longer body line establishes the document body size.",
			bounds: bodyBounds,
			size: 11)
		let semantics = DocumentSemantics(
			referenceSize: pageSize,
			blocks: [
				normalizedParagraph(text: title.combinedText, bounds: titleBounds),
				normalizedParagraph(text: body.combinedText, bounds: bodyBounds)
			],
			images: [])

		let blocks = TextLineSemanticComposer.composeBlocks(
			from: [title, body], semantics: semantics, layoutSize: pageSize)
		let markdown = DocumentBlockMarkdownRenderer.markdown(from: blocks)

		#expect(markdown.contains("# Title\n\nA much longer body line"))
	}

	@Test("An explicit heading does not absorb an unmatched body line")
	func explicitHeadingDoesNotAbsorbRemainingLine() {
		let titleBounds = CGRect(x: 50, y: 20, width: 200, height: 20)
		let bodyBounds = CGRect(x: 50, y: 43, width: 400, height: 20)
		let title = textLine("Known heading", bounds: titleBounds, size: 11, bold: true)
		let body = textLine("Body line remains a paragraph.", bounds: bodyBounds, size: 11)
		let semantics = semanticsForParagraph(
			text: title.combinedText,
			bounds: titleBounds,
			headingLevel: 2)

		let blocks = TextLineSemanticComposer.composeBlocks(
			from: [title, body], semantics: semantics, layoutSize: pageSize)
		let markdown = DocumentBlockMarkdownRenderer.markdown(from: blocks)

		#expect(markdown.contains("## Known heading\n\nBody line remains a paragraph."))
	}

	@Test("Adjacent bold body lines are reconstructed before heading inference")
	func splitBoldBodyParagraphIsNotAHeading() throws {
		let firstBounds = CGRect(x: 50, y: 100, width: 180, height: 20)
		let secondBounds = CGRect(x: 50, y: 121, width: 180, height: 20)
		let first = textLine("Important information", bounds: firstBounds, size: 11, bold: true)
		let second = textLine("please read carefully.", bounds: secondBounds, size: 11, bold: true)
		let semantics = DocumentSemantics(
			referenceSize: pageSize,
			blocks: [
				normalizedParagraph(text: first.combinedText, bounds: firstBounds),
				normalizedParagraph(text: second.combinedText, bounds: secondBounds)
			],
			images: [])

		let blocks = TextLineSemanticComposer.composeBlocks(
			from: [first, second], semantics: semantics, layoutSize: pageSize)
		let paragraphs = blocks.compactMap { block -> DocumentBlock.Paragraph? in
			guard case .paragraph(let paragraph) = block.kind else { return nil }
			return paragraph
		}
		let paragraph = try #require(paragraphs.first)
		let markdown = DocumentBlockMarkdownRenderer.markdown(from: blocks)

		#expect(paragraphs.count == 1)
		#expect(paragraph.lines.count == 2)
		#expect(markdown.contains("**Important information please read carefully.**"))
		#expect(!markdown.contains("# Important information"))
	}

	/// Bold body text on both sides, but `Wear` would have fitted after
	/// `Safety`: that line was ended on purpose, so it is a heading, not the
	/// first line of a wrapped bold paragraph.
	@Test("A bold body-size heading stays separate from a bold sentence below it")
	func boldHeadingAboveBoldSentenceStaysAHeading() {
		let bodyBounds = CGRect(x: 50, y: 40, width: 400, height: 20)
		let headingBounds = CGRect(x: 50, y: 100, width: 45, height: 20)
		let sentenceBounds = CGRect(x: 50, y: 121, width: 90, height: 20)
		let body = textLine(
			"A body paragraph long enough to establish the width of the column.",
			bounds: bodyBounds,
			size: 11)
		let heading = textLine("Safety", bounds: headingBounds, size: 11, bold: true)
		let sentence = textLine("Wear gloves.", bounds: sentenceBounds, size: 11, bold: true)
		let semantics = DocumentSemantics(
			referenceSize: pageSize,
			blocks: [
				normalizedParagraph(text: body.combinedText, bounds: bodyBounds),
				normalizedParagraph(text: heading.combinedText, bounds: headingBounds),
				normalizedParagraph(text: sentence.combinedText, bounds: sentenceBounds)
			],
			images: [])

		let blocks = TextLineSemanticComposer.composeBlocks(
			from: [body, heading, sentence], semantics: semantics, layoutSize: pageSize)
		let markdown = DocumentBlockMarkdownRenderer.markdown(from: blocks)

		#expect(markdown.contains("# Safety\n\n**Wear gloves.**"))
	}

	/// A title and a banner share the column's left edge but run wider than it.
	/// Neither is a wrapped line of body text, so neither says where the column
	/// ends: the body paragraph's wrapped line does.
	@Test("A wide title or banner does not stretch the column a bold paragraph wraps in")
	func wideTitleDoesNotWidenTheColumn() {
		let lines = [
			textLine("Quarterly report for our partners", bounds: CGRect(x: 50, y: 20, width: 500, height: 26), size: 22),
			textLine(
				"Confidential and for internal use only, please do not forward",
				bounds: CGRect(x: 50, y: 80, width: 500, height: 20), size: 11),
			textLine("Body text in the narrow column that", bounds: CGRect(x: 50, y: 130, width: 200, height: 20), size: 11),
			textLine("wraps onto a second line.", bounds: CGRect(x: 50, y: 151, width: 140, height: 20), size: 11),
			textLine("Important information", bounds: CGRect(x: 50, y: 220, width: 190, height: 20), size: 11, bold: true),
			textLine("please read carefully.", bounds: CGRect(x: 50, y: 241, width: 180, height: 20), size: 11, bold: true)
		]
		let markdown = composedMarkdown(lines, paragraphs: [[0], [1], [2, 3], [4], [5]])

		#expect(markdown.contains("**Important information please read carefully.**"))
		#expect(!markdown.contains("# Important information"))
	}

	/// A full-width passage above a two-column page shares the left column's
	/// edge, and its lines wrapped too — but the right column starts where it
	/// runs on, so it cannot be the left column's width.
	@Test("A full-width passage does not stretch a column that text stands beside")
	func fullWidthPassageDoesNotWidenAColumnBesideAnother() {
		let lines = [
			textLine(
				"A full-width abstract that spans both of the columns below it and",
				bounds: CGRect(x: 50, y: 20, width: 500, height: 20), size: 11),
			textLine("wraps onto a second line.", bounds: CGRect(x: 50, y: 41, width: 150, height: 20), size: 11),
			textLine("The right column starts beside", bounds: CGRect(x: 320, y: 200, width: 200, height: 20), size: 11),
			textLine("the left one and runs on down", bounds: CGRect(x: 320, y: 221, width: 200, height: 20), size: 11),
			textLine("the page.", bounds: CGRect(x: 320, y: 242, width: 60, height: 20), size: 11),
			textLine("Important information", bounds: CGRect(x: 50, y: 221, width: 190, height: 20), size: 11, bold: true),
			textLine("please read carefully.", bounds: CGRect(x: 50, y: 242, width: 180, height: 20), size: 11, bold: true)
		]
		let markdown = composedMarkdown(lines, paragraphs: [[0, 1], [2, 3, 4], [5], [6]])

		#expect(markdown.contains("**Important information please read carefully.**"))
		#expect(!markdown.contains("# Important information"))
	}

	/// On a title-plus-table page the table is the running text. Its cells take
	/// the page's own lines, and with them the size they are set at.
	@Test("Table text counts toward the body size")
	func tableTextCountsTowardTheBodySize() throws {
		let titleBounds = CGRect(x: 50, y: 20, width: 200, height: 26)
		let title = textLine("Quartalsbericht", bounds: titleBounds, size: 22)
		let cellTexts = [["Umsatz", "1.200.000 Euro"], ["Gewinn", "300.000 Euro"]]
		var cellLines: [TextLine] = []
		var rows: [[DocumentBlock.Table.Cell]] = []
		var normalizedRows: [[NormalizedDocumentBlock.NormalizedTableCell]] = []
		for (rowIndex, row) in cellTexts.enumerated() {
			var cells: [DocumentBlock.Table.Cell] = []
			var normalizedCells: [NormalizedDocumentBlock.NormalizedTableCell] = []
			for (columnIndex, text) in row.enumerated() {
				let bounds = CGRect(
					x: 50 + CGFloat(columnIndex) * 200, y: 100 + CGFloat(rowIndex) * 30, width: 150, height: 20)
				cellLines.append(textLine(text, bounds: bounds, size: 11))
				let cell = DocumentBlock.Table.Cell(
					rowRange: rowIndex...rowIndex,
					columnRange: columnIndex...columnIndex,
					text: text,
					bounds: bounds,
					lines: [DocumentBlock.TextLine(text: text, bounds: bounds)])
				cells.append(cell)
				normalizedCells.append(.init(normalizedBounds: normalized(bounds), cell: cell))
			}
			rows.append(cells)
			normalizedRows.append(normalizedCells)
		}
		let tableBounds = CGRect(x: 50, y: 100, width: 350, height: 50)
		let table = DocumentBlock(bounds: tableBounds, kind: .table(.init(rows: rows)))
		let semantics = DocumentSemantics(
			referenceSize: pageSize,
			blocks: [
				normalizedParagraph(text: title.combinedText, bounds: titleBounds),
				NormalizedDocumentBlock(
					block: table, normalizedBounds: normalized(tableBounds), tableRows: normalizedRows)
			],
			images: [])

		let blocks = TextLineSemanticComposer.composeBlocks(
			from: [title] + cellLines, semantics: semantics, layoutSize: pageSize)
		let markdown = DocumentBlockMarkdownRenderer.markdown(from: blocks)

		#expect(markdown.contains("# Quartalsbericht"))
		#expect(markdown.contains("|Umsatz|1.200.000 Euro|"))
	}

	/// A PDF text layer usually sets a whole table row as one line. Only one
	/// cell consumes it, but every cell of the row finds its text there.
	@Test("Table cells take their style from a line spanning the whole row")
	func tableCellsReadTheirStyleFromARowLine() throws {
		let titleBounds = CGRect(x: 50, y: 20, width: 200, height: 26)
		let title = textLine("Quartalsbericht", bounds: titleBounds, size: 22)
		let rowTexts = [("Umsatz", "1.200.000 Euro"), ("Gewinn", "300.000 Euro")]
		var rowLines: [TextLine] = []
		var rows: [[DocumentBlock.Table.Cell]] = []
		var normalizedRows: [[NormalizedDocumentBlock.NormalizedTableCell]] = []
		for (rowIndex, texts) in rowTexts.enumerated() {
			let y = 100 + CGFloat(rowIndex) * 30
			let left = CGRect(x: 50, y: y, width: 60, height: 20)
			let right = CGRect(x: 250, y: y, width: 110, height: 20)
			let style = TextStyle(fontSize: 11)
			rowLines.append(TextLine(fragments: [
				TextFragment(bounds: left, string: texts.0, styleRuns: [StyleRun(text: texts.0, style: style)]),
				TextFragment(bounds: right, string: texts.1, styleRuns: [StyleRun(text: texts.1, style: style)])
			]))
			let cells = [(texts.0, left, 0), (texts.1, right, 1)].map { text, bounds, column in
				DocumentBlock.Table.Cell(
					rowRange: rowIndex...rowIndex, columnRange: column...column, text: text, bounds: bounds,
					lines: [DocumentBlock.TextLine(text: text, bounds: bounds)])
			}
			rows.append(cells)
			normalizedRows.append(cells.map { .init(normalizedBounds: normalized($0.bounds), cell: $0) })
		}
		let tableBounds = CGRect(x: 50, y: 100, width: 310, height: 50)
		let table = DocumentBlock(bounds: tableBounds, kind: .table(.init(rows: rows)))
		let semantics = DocumentSemantics(
			referenceSize: pageSize,
			blocks: [
				normalizedParagraph(text: title.combinedText, bounds: titleBounds),
				NormalizedDocumentBlock(
					block: table, normalizedBounds: normalized(tableBounds), tableRows: normalizedRows)
			],
			images: [])

		let blocks = TextLineSemanticComposer.composeBlocks(
			from: [title] + rowLines, semantics: semantics, layoutSize: pageSize)
		let cells = blocks.flatMap { block -> [DocumentBlock.Table.Cell] in
			guard case .table(let table) = block.kind else { return [] }
			return table.rows.flatMap { $0 }
		}

		#expect(cells.count == 4)
		#expect(cells.allSatisfy { cell in cell.lines.allSatisfy { !$0.runs.isEmpty } })
		#expect(DocumentBlockMarkdownRenderer.markdown(from: blocks).contains("# Quartalsbericht"))
	}

	@Test("A text-layer line appended to a paragraph keeps its emphasis")
	func appendedLineKeepsStyleRuns() throws {
		let firstBounds = CGRect(x: 50, y: 100, width: 180, height: 20)
		let secondBounds = CGRect(x: 50, y: 121, width: 120, height: 20)
		let first = textLine("Normal text", bounds: firstBounds, size: 11)
		let second = textLine("important.", bounds: secondBounds, size: 11, bold: true)
		let semantics = semanticsForParagraph(text: first.combinedText, bounds: firstBounds)

		let blocks = TextLineSemanticComposer.composeBlocks(
			from: [first, second], semantics: semantics, layoutSize: pageSize)
		let paragraph = try #require(blocks.compactMap { block -> DocumentBlock.Paragraph? in
			guard case .paragraph(let paragraph) = block.kind else { return nil }
			return paragraph
		}.first)

		#expect(paragraph.lines.count == 2)
		#expect(!paragraph.lines[1].runs.isEmpty)
		#expect(DocumentBlockMarkdownRenderer.markdown(from: blocks)
			.contains("Normal text **important.**"))
	}

	@Test("Semantic paragraph heading metadata survives composition")
	func explicitHeadingLevelSurvivesComposition() throws {
		let bounds = CGRect(x: 50, y: 50, width: 200, height: 20)
		let line = textLine("Known heading", bounds: bounds, size: 11)
		let semantics = semanticsForParagraph(
			text: line.combinedText,
			bounds: bounds,
			headingLevel: 3)

		let blocks = TextLineSemanticComposer.composeBlocks(
			from: [line], semantics: semantics, layoutSize: pageSize)
		let paragraph = try #require(blocks.compactMap { block -> DocumentBlock.Paragraph? in
			guard case .paragraph(let paragraph) = block.kind else { return nil }
			return paragraph
		}.first)

		#expect(paragraph.headingLevel == 3)
		#expect(DocumentBlockMarkdownRenderer.markdown(from: blocks).contains("### Known heading"))
	}

	/// Composes `lines` with one semantic paragraph per group of line indices,
	/// the way the segmenter would report them, and renders the result.
	private func composedMarkdown(_ lines: [TextLine], paragraphs: [[Int]]) -> String {
		let blocks = paragraphs.map { group -> NormalizedDocumentBlock in
			let bounds = group.map { lines[$0].fragments[0].bounds }.reduce(CGRect.null) { $0.union($1) }
			let text = group.map { lines[$0].combinedText }.joined(separator: "\n")
			return normalizedParagraph(text: text, bounds: bounds)
		}
		let semantics = DocumentSemantics(referenceSize: pageSize, blocks: blocks, images: [])
		let composed = TextLineSemanticComposer.composeBlocks(
			from: lines, semantics: semantics, layoutSize: pageSize)
		return DocumentBlockMarkdownRenderer.markdown(from: composed)
	}

	private func textLine(
		_ text: String,
		bounds: CGRect,
		size: CGFloat,
		bold: Bool = false
	) -> TextLine {
		let style = TextStyle(fontSize: size, isBold: bold, isItalic: false, isMonospaced: false)
		let run = StyleRun(text: text, style: style)
		return TextLine(fragments: [TextFragment(bounds: bounds, string: text, styleRuns: [run])])
	}

	private func semanticsForParagraph(
		text: String,
		bounds: CGRect,
		headingLevel: Int? = nil
	) -> DocumentSemantics {
		let line = DocumentBlock.TextLine(text: text, bounds: bounds)
		let paragraph = DocumentBlock.Paragraph(
			text: text,
			lines: [line],
			headingLevel: headingLevel)
		let block = DocumentBlock(bounds: bounds, kind: .paragraph(paragraph))
		return DocumentSemantics(
			referenceSize: pageSize,
			blocks: [NormalizedDocumentBlock(block: block, normalizedBounds: normalized(bounds))],
			images: [])
	}

	private func normalizedParagraph(
		text: String,
		bounds: CGRect,
		headingLevel: Int? = nil
	) -> NormalizedDocumentBlock {
		let line = DocumentBlock.TextLine(text: text, bounds: bounds)
		let paragraph = DocumentBlock.Paragraph(
			text: text,
			lines: [line],
			headingLevel: headingLevel)
		return NormalizedDocumentBlock(
			block: DocumentBlock(bounds: bounds, kind: .paragraph(paragraph)),
			normalizedBounds: normalized(bounds))
	}

	private func normalized(_ rect: CGRect) -> NormalizedRect {
		NormalizedRect(
			minX: rect.minX / pageSize.width,
			minY: rect.minY / pageSize.height,
			width: rect.width / pageSize.width,
			height: rect.height / pageSize.height)
	}
}
