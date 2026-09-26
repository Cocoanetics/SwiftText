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
