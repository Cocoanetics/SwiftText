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

	/// An item need not report its marker. The kind of list then says which
	/// family of marker to look for.
	@Test("A painted marker is dropped even when none was reported", arguments: [
		("• Punkt", DocumentBlock.List.Marker.bullet),
		("◦ Punkt", .bullet),
		("▪ Punkt", .bullet),
		("- Punkt", .hyphen),
		("– Punkt", .hyphen),
		("* Punkt", .bullet),
		("1) Punkt", .decimal),
		("a) Punkt", .lowercaseLatin),
		("B. Punkt", .uppercaseLatin),
		("1.2. Punkt", .compositeDecimal),
		("•Punkt", .bullet)
	])
	func paintedMarkerWithoutAReportedOne(_ testCase: (painted: String, marker: DocumentBlock.List.Marker)) {
		let blocks = composeList(itemTexts: [testCase.painted], markerString: "", marker: testCase.marker)
		#expect(itemTexts(of: blocks) == ["Punkt"])
	}

	/// A PDF can leave the painted bullet out of its text layer, and then what
	/// remains is content. Only a marker of the list's own kind can be one.
	@Test("A list keeps content shaped like another kind of marker", arguments: [
		("A. Smith", DocumentBlock.List.Marker.bullet),
		("1. Introduction", .bullet),
		("a) Hinweis", .hyphen),
		("A. Smith", .lowercaseLatin),
		("A. Smith", .decimal),
		("2. Quartal", .uppercaseLatin)
	])
	func contentShapedLikeAnotherKindOfMarker(_ testCase: (text: String, marker: DocumentBlock.List.Marker)) {
		let blocks = composeList(itemTexts: [testCase.text], markerString: "", marker: testCase.marker)
		#expect(itemTexts(of: blocks) == [testCase.text])
	}

	/// With nothing reported about the list at all, only a bullet glyph — which
	/// no content begins with — can be taken for a marker.
	@Test("Without a known kind of list only a bullet glyph is a marker", arguments: [
		("• Punkt", "Punkt"),
		("A. Smith", "A. Smith"),
		("1. Introduction", "1. Introduction"),
		("- 5 Grad", "- 5 Grad")
	])
	func unknownListKindDropsOnlyABulletGlyph(_ testCase: (text: String, expected: String)) {
		let blocks = composeList(itemTexts: [testCase.text], markerString: "", marker: .custom(""))
		#expect(itemTexts(of: blocks) == [testCase.expected])
	}

	/// The segmenter reads an item's content apart from its marker. A text-layer
	/// line that already begins with that reading carries no marker, however
	/// marker-shaped its opening — a PDF can leave the painted marker out of its
	/// text layer — and otherwise loses exactly what stands in front of it.
	@Test("The segmenter's reading decides whether a marker is there", arguments: [
		("A. Smith", "A. Smith", "A.", DocumentBlock.List.Marker.uppercaseLatin, "A. Smith"),
		("A. A. Smith", "A. Smith", "A.", .uppercaseLatin, "A. Smith"),
		("1. Introduction", "1. Introduction", "1.", .decimal, "1. Introduction"),
		("1. 1. Introduction", "1. Introduction", "1.", .decimal, "1. Introduction"),
		("• Punkt eins", "Punkt eins", "•", .bullet, "Punkt eins"),
		("• geprüft wird", "gepruft wird", "•", .bullet, "geprüft wird")
	])
	func segmentedReadingDecides(
		_ testCase: (text: String, segmented: String, reported: String, marker: DocumentBlock.List.Marker, expected: String)
	) {
		let blocks = composeList(
			itemTexts: [testCase.text],
			segmentedTexts: [testCase.segmented],
			markerString: testCase.reported,
			marker: testCase.marker)
		#expect(itemTexts(of: blocks) == [testCase.expected])
	}

	/// When the two readings cannot be matched up — a recognition error in the
	/// segmenter's — the reported marker and the list's kind decide as before.
	@Test("A reading that does not match falls back to the reported marker")
	func unmatchedReadingFallsBack() {
		let blocks = composeList(
			itemTexts: ["• Pnkt eins"],
			segmentedTexts: ["Punkt eins"],
			markerString: "•",
			marker: .bullet)
		#expect(itemTexts(of: blocks) == ["Pnkt eins"])
	}

	@Test("A bullet glyph is dropped from segmented content whatever was reported", arguments: [
		("● Punkt", "Punkt" as String?),
		("•Punkt", "Punkt"),
		("A. Smith", nil),
		("- Punkt", nil)
	])
	func bulletGlyphIsDroppedFromSegmentedContent(_ testCase: (content: String, expected: String?)) {
		#expect(strippingBulletGlyph(testCase.content) == testCase.expected)
	}

	/// A hyphen doubles as a minus sign, so even a reported one is a marker only
	/// with a space after it.
	@Test("A reported hyphen marker needs a space after it", arguments: [
		("- -5 Grad", "-5 Grad"),
		("-5 Grad", "-5 Grad")
	])
	func reportedHyphenNeedsASpace(_ testCase: (text: String, expected: String)) {
		let blocks = composeList(itemTexts: [testCase.text], markerString: "-", marker: .hyphen)
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

	@Test("An inaccurate reported ordinal does not consume decimal content")
	func reportedOrdinalDoesNotConsumeDecimal() {
		let blocks = composeList(
			itemTexts: ["1.5 Millionen", "1. Punkt"],
			markerString: "1",
			marker: .decimal)
		#expect(itemTexts(of: blocks) == ["1.5 Millionen", "Punkt"])
	}

	@Test("A reported bullet does not make clean Latin content a marker")
	func omittedPaintedBulletKeepsCleanContent() {
		let blocks = composeList(
			itemTexts: ["A. Smith"],
			markerString: "•",
			marker: .bullet)
		#expect(itemTexts(of: blocks) == ["A. Smith"])
	}

	@Test("A non-breaking space separates a reported or inferred marker", arguments: [
		("1.\u{00A0}Punkt", "1.", DocumentBlock.List.Marker.decimal),
		("1.\u{00A0}Punkt", "", .decimal),
		("a)\u{00A0}Punkt", "", .lowercaseLatin),
		("1.2.\u{00A0}Punkt", "", .compositeDecimal)
	])
	func nonBreakingSpaceAfterMarker(
		_ testCase: (painted: String, reported: String, marker: DocumentBlock.List.Marker)
	) {
		let blocks = composeList(
			itemTexts: [testCase.painted],
			markerString: testCase.reported,
			marker: testCase.marker)
		#expect(itemTexts(of: blocks) == ["Punkt"])
	}

	/// Vision's own item content still begins with the marker it reports
	/// separately. That marker, and nothing else, is taken off it.
	@Test("Segmented content loses exactly the reported marker", arguments: [
		("• Punkt eins", "• ", "Punkt eins"),
		("• A. Smith", "•", "A. Smith"),
		("1. Erster Schritt", "1. ", "Erster Schritt"),
		("a) Hinweis", "a)", "Hinweis")
	])
	func segmentedContentLosesTheReportedMarker(_ testCase: (content: String, reported: String, expected: String)) {
		#expect(strippingReportedMarker(testCase.content, reportedMarker: testCase.reported) == testCase.expected)
	}

	@Test("Segmented content without the reported marker is left alone", arguments: [
		("A. Smith", "•"),
		("1.5 Millionen", "1"),
		("- nicht der Marker", "•"),
		("Punkt eins", "")
	])
	func segmentedContentWithoutTheReportedMarker(_ testCase: (content: String, reported: String)) {
		#expect(strippingReportedMarker(testCase.content, reportedMarker: testCase.reported) == nil)
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
	/// way a PDF text layer delivers them. `segmentedTexts`, when given, are the
	/// segmenter's own marker-free readings of the items.
	private func composeList(
		itemTexts: [String],
		segmentedTexts: [String]? = nil,
		markerString: String,
		marker: DocumentBlock.List.Marker
	) -> [DocumentBlock] {
		let pageSize = CGSize(width: 600, height: 800)
		let lineHeight: CGFloat = 20
		var textLines: [TextLine] = []
		var items: [DocumentBlock.List.Item] = []
		var normalizedItems: [NormalizedDocumentBlock.NormalizedListItem] = []
		var y: CGFloat = 100

		for (index, itemText) in itemTexts.enumerated() {
			let itemTop = y
			for line in itemText.components(separatedBy: "\n") {
				let bounds = CGRect(x: 50, y: y, width: 400, height: lineHeight)
				textLines.append(TextLine(fragments: [TextFragment(bounds: bounds, string: line)]))
				y += lineHeight
			}
			let itemBounds = CGRect(x: 50, y: itemTop, width: 400, height: y - itemTop)
			let segmented = segmentedTexts?[index] ?? ""
			let item = DocumentBlock.List.Item(
				text: segmented,
				markerString: markerString,
				bounds: itemBounds,
				lines: segmented.isEmpty ? [] : [DocumentBlock.TextLine(text: segmented, bounds: itemBounds)])
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
