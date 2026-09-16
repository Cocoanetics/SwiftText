//
//  ListMarkerTests.swift
//  SwiftTextOCRTests
//

import Foundation
import Testing

@testable import SwiftTextOCR

/// Markdown writes a list item's marker itself, so a marker that survives into
/// the item's *text* is written twice: `- • Punkt eins`. That happens when the
/// text comes from a PDF's own text layer, where the bullet is a painted glyph
/// like any other character.
struct ListMarkerTests {
	@Test("A composed list item drops the marker painted in the text layer")
	func composedListItemDropsPaintedMarker() {
		let blocks = composeList(
			itemTexts: ["• Punkt eins", "• Punkt zwei"],
			markerString: "• ",
			marker: .bullet)
		#expect(itemTexts(of: blocks) == ["Punkt eins", "Punkt zwei"])
	}

	@Test("A composed list item drops an ordinal painted in the text layer")
	func composedListItemDropsPaintedOrdinal() {
		let blocks = composeList(
			itemTexts: ["1. Erster", "2. Zweiter"],
			markerString: "",
			marker: .decimal)
		#expect(itemTexts(of: blocks) == ["Erster", "Zweiter"])
	}

	/// The segmenter's reported marker and the painted one need not agree, so a
	/// marker is recognised on its own too.
	@Test("A painted marker is dropped even when none was reported", arguments: [
		("• Punkt", "Punkt"),
		("◦ Punkt", "Punkt"),
		("▪ Punkt", "Punkt"),
		("- Punkt", "Punkt"),
		("– Punkt", "Punkt"),
		("* Punkt", "Punkt"),
		("1) Punkt", "Punkt"),
		("•Punkt", "Punkt")
	])
	func paintedMarkerWithoutAReportedOne(_ testCase: (painted: String, expected: String)) {
		let blocks = composeList(itemTexts: [testCase.painted], markerString: "", marker: .bullet)
		#expect(itemTexts(of: blocks) == [testCase.expected])
	}

	/// Only the marker goes. Text that merely looks like one in the middle of an
	/// item, or a hyphenated word, is the item's own content.
	@Test("Content that resembles a marker is left alone", arguments: [
		("Wort - mit Gedankenstrich", "Wort - mit Gedankenstrich"),
		("E-Mail schreiben", "E-Mail schreiben"),
		("2026 war das Jahr", "2026 war das Jahr"),
		("5 * 3 ergibt 15", "5 * 3 ergibt 15"),
		("1.5 Millionen Euro", "1.5 Millionen Euro"),
		("3.Quartal ohne Leerzeichen", "3.Quartal ohne Leerzeichen")
	])
	func contentResemblingAMarker(_ testCase: (painted: String, expected: String)) {
		let blocks = composeList(itemTexts: [testCase.painted], markerString: "", marker: .bullet)
		#expect(itemTexts(of: blocks) == [testCase.expected])
	}

	@Test("Only the first line of a multi-line item loses a marker")
	func onlyTheFirstLineLosesAMarker() {
		let blocks = composeList(
			itemTexts: ["• Punkt eins\n- nicht der Marker"],
			markerString: "• ",
			marker: .bullet)
		#expect(itemTexts(of: blocks) == ["Punkt eins\n- nicht der Marker"])
	}

	// MARK: - Helpers

	/// Compose a one-list page whose text lines carry `itemTexts` verbatim, the
	/// way a PDF text layer delivers them.
	private func composeList(
		itemTexts: [String],
		markerString: String,
		marker: DocumentBlock.List.Marker
	) -> [DocumentBlock] {
		let pageSize = CGSize(width: 600, height: 800)
		let lineHeight: CGFloat = 20
		var textLines: [TextLine] = []
		var items: [DocumentBlock.List.Item] = []
		var normalizedItems: [NormalizedDocumentBlock.NormalizedListItem] = []
		var y: CGFloat = 100

		for itemText in itemTexts {
			let itemTop = y
			for line in itemText.components(separatedBy: "\n") {
				let bounds = CGRect(x: 50, y: y, width: 400, height: lineHeight)
				textLines.append(TextLine(fragments: [TextFragment(bounds: bounds, string: line)]))
				y += lineHeight
			}
			let itemBounds = CGRect(x: 50, y: itemTop, width: 400, height: y - itemTop)
			let item = DocumentBlock.List.Item(
				text: "", markerString: markerString, bounds: itemBounds, lines: [])
			items.append(item)
			normalizedItems.append(.init(normalizedBounds: normalized(itemBounds, in: pageSize), item: item))
		}

		let listBounds = CGRect(x: 50, y: 100, width: 400, height: y - 100)
		let list = DocumentBlock.List(marker: marker, items: items)
		let block = DocumentBlock(bounds: listBounds, kind: .list(list))
		let semantics = DocumentSemantics(
			referenceSize: pageSize,
			blocks: [NormalizedDocumentBlock(
				block: block,
				normalizedBounds: normalized(listBounds, in: pageSize),
				listItems: normalizedItems)],
			images: [])
		return TextLineSemanticComposer.composeBlocks(
			from: textLines, semantics: semantics, layoutSize: pageSize)
	}

	private func normalized(_ rect: CGRect, in size: CGSize) -> NormalizedRect {
		NormalizedRect(
			minX: rect.minX / size.width, minY: rect.minY / size.height,
			width: rect.width / size.width, height: rect.height / size.height)
	}

	private func itemTexts(of blocks: [DocumentBlock]) -> [String] {
		blocks.flatMap { block -> [String] in
			guard case .list(let list) = block.kind else { return [] }
			return list.items.map(\.text)
		}
	}
}
