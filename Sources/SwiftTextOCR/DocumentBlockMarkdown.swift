//
//  DocumentBlockMarkdown.swift
//  SwiftTextPDF
//
//  Created by OpenAI Codex on 12.12.24.
//

import Foundation
import Markdown

public struct DocumentBlockMarkdownRenderer {

	/// Builds a swift-markdown `Document` from OCR-extracted blocks, using the
	/// same geometric reading-order heuristics as the legacy renderer.
	///
	/// Returning a `Document` (rather than a string) lets callers compose the
	/// result with any other AST consumer — `MarkupFormatter`, the visitor that
	/// drives `MarkdownToHTML`, the DOCX builder, structural diffing, linting,
	/// and so on. `markdown(from:textLines:imageResolver:)` is the convenience
	/// shim that calls `MarkupFormatter.format` on this output.
	public static func document(
		from blocks: [DocumentBlock],
		textLines: [DocumentBlock.TextLine]? = nil,
		imageResolver: ((DocumentBlock) -> String?)? = nil
	) -> Document {
		let ordered = orderedBlocks(blocks, textLines: textLines)
		let merged = mergeParagraphContinuations(ordered, pageBounds: boundsForPage(from: ordered, textLines: textLines))
		let blockMarkup: [BlockMarkup] = merged.compactMap { block -> BlockMarkup? in
			switch block.kind {
			case .paragraph(let paragraph):
				return makeParagraph(paragraph)
			case .list(let list):
				return makeList(list)
			case .table(let table):
				return makeTable(table)
			case .image:
				return makeImage(resolved: imageResolver?(block))
			}
		}
		return Document(blockMarkup)
	}

	/// Renders OCR-extracted blocks to a Markdown string via swift-markdown's
	/// `MarkupFormatter`. This goes through the AST so pipe escaping, alignment
	/// markers, list nesting, and paragraph wrapping are all handled by cmark
	/// rather than ad-hoc string code.
	public static func markdown(
		from blocks: [DocumentBlock],
		textLines: [DocumentBlock.TextLine]? = nil,
		imageResolver: ((DocumentBlock) -> String?)? = nil
	) -> String {
		let doc = document(from: blocks, textLines: textLines, imageResolver: imageResolver)
		// Use incrementing numerals for ordered lists. The formatter's default
		// (`allSame`) emits `1.` for every item — CommonMark-legal but visually
		// confusing for non-renderer consumers (LLMs, diff tools).
		let options = MarkupFormatter.Options(orderedListNumerals: .incrementing(start: 1))
		return doc.format(options: options)
	}

	// MARK: - Block builders

	private static func makeParagraph(_ paragraph: DocumentBlock.Paragraph) -> Paragraph? {
		let lines = paragraph.lines
			.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		let text = lines.isEmpty
			? paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
			: lines.joined(separator: " ")
		guard !text.isEmpty else { return nil }
		return Paragraph(Text(text))
	}

	private static func makeList(_ list: DocumentBlock.List) -> BlockMarkup? {
		guard !list.items.isEmpty else { return nil }
		let listItems: [ListItem] = list.items.map { item in
			let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
			return ListItem(Paragraph(Text(text)))
		}
		// OCR-detected markers (`iii.`, `(a)`, custom strings) are visual labels
		// that don't survive Markdown's `-` / `1.` syntax. Normalize ordered
		// markers to a numbered list and everything else to a bullet list — the
		// reader of the Markdown gets the structural intent, which is what they
		// actually need.
		switch list.marker {
		case .decimal, .decorativeDecimal, .compositeDecimal,
		     .lowercaseLatin, .uppercaseLatin:
			return OrderedList(listItems)
		case .bullet, .hyphen, .custom:
			return UnorderedList(listItems)
		}
	}

	private static func makeTable(_ table: DocumentBlock.Table) -> Markdown.Table? {
		let columnCount = table.rows.map(\.count).max() ?? 0
		guard columnCount > 0, !table.rows.isEmpty else { return nil }

		// MarkupFormatter handles `\|` escaping inside cell text on its own, so
		// we just feed the raw cell text through.
		func makeCell(_ cellText: String) -> Markdown.Table.Cell {
			let trimmed = cellText.trimmingCharacters(in: .whitespacesAndNewlines)
			return Markdown.Table.Cell(Text(trimmed))
		}

		let headerRow = table.rows[0]
		var headerCells: [Markdown.Table.Cell] = headerRow.map { makeCell($0.text) }
		while headerCells.count < columnCount {
			headerCells.append(Markdown.Table.Cell())
		}

		let bodyRows: [Markdown.Table.Row] = table.rows.dropFirst().map { row in
			var cells = row.map { makeCell($0.text) }
			while cells.count < columnCount {
				cells.append(Markdown.Table.Cell())
			}
			return Markdown.Table.Row(cells)
		}

		// `DocumentBlock.Table` doesn't carry alignment info — emit nil
		// (`MarkupFormatter` then writes a plain `---` separator).
		return Markdown.Table(
			columnAlignments: Array(repeating: nil, count: columnCount),
			header: Markdown.Table.Head(headerCells),
			body: Markdown.Table.Body(bodyRows)
		)
	}

	private static func makeImage(resolved: String?) -> Paragraph {
		let source = resolved.flatMap { $0.isEmpty ? nil : $0 }
		return Paragraph(Image(source: source ?? "", Text("Image")))
	}

	// MARK: - Reading-order heuristics (unchanged from the legacy renderer)

	private static func orderedBlocks(
		_ blocks: [DocumentBlock],
		textLines: [DocumentBlock.TextLine]?
	) -> [DocumentBlock] {
		let pageBounds = boundsForPage(from: blocks, textLines: textLines)
		if let lines = textLines, !lines.isEmpty {
			return blocks.enumerated().sorted { lhs, rhs in
				let lhsOrder = orderIndex(for: lhs.element.bounds, textLines: lines, pageBounds: pageBounds)
				let rhsOrder = orderIndex(for: rhs.element.bounds, textLines: lines, pageBounds: pageBounds)

				let lhsAnchor = lhsOrder != Int.max
				let rhsAnchor = rhsOrder != Int.max

				let lhsRect = lhsAnchor ? normalize(lines[lhsOrder].bounds, in: pageBounds) : normalize(lhs.element.bounds, in: pageBounds)
				let rhsRect = rhsAnchor ? normalize(lines[rhsOrder].bounds, in: pageBounds) : normalize(rhs.element.bounds, in: pageBounds)

				let verticalDelta = lhsRect.minY - rhsRect.minY
				if abs(verticalDelta) > 0.01 {
					return verticalDelta < 0
				}

				if lhsRect.minX != rhsRect.minX {
					return lhsRect.minX < rhsRect.minX
				}

				return lhs.offset < rhs.offset
			}.map(\.element)
		}
		return blocks.sorted { lhs, rhs in
			isInReadingOrder(lhs.bounds, rhs.bounds, pageBounds: pageBounds)
		}
	}

	private static func boundsForPage(from blocks: [DocumentBlock], textLines: [DocumentBlock.TextLine]?) -> CGRect {
		if let lines = textLines, !lines.isEmpty {
			let union = lines.reduce(into: CGRect.null) { partial, line in
				partial = partial.union(line.bounds)
			}
			if !union.isNull {
				return union
			}
		}

		let blockUnion = blocks.reduce(into: CGRect.null) { partial, block in
			partial = partial.union(block.bounds)
		}

		if !blockUnion.isNull {
			return blockUnion
		}

		return CGRect(origin: .zero, size: CGSize(width: 1, height: 1))
	}

	private static func normalize(_ rect: CGRect, in pageBounds: CGRect) -> CGRect {
		guard pageBounds.width > 0, pageBounds.height > 0 else { return rect }
		return CGRect(
			x: (rect.minX - pageBounds.minX) / pageBounds.width,
			y: (rect.minY - pageBounds.minY) / pageBounds.height,
			width: rect.width / pageBounds.width,
			height: rect.height / pageBounds.height
		)
	}

	private static func mergeParagraphContinuations(_ blocks: [DocumentBlock], pageBounds: CGRect) -> [DocumentBlock] {
		guard !blocks.isEmpty else { return blocks }
		var result: [DocumentBlock] = []
		let maxLeftDelta = max(pageBounds.width * 0.02, 8)

		for block in blocks {
			guard
				case .paragraph(let currentParagraph) = block.kind,
				let last = result.last,
				case .paragraph(let previousParagraph) = last.kind
			else {
				result.append(block)
				continue
			}

			let verticalGap = block.bounds.minY - last.bounds.maxY
			let avgHeight = max((block.bounds.height + last.bounds.height) / 2, 1)
			let maxGap = max(avgHeight * 0.8, 6)
			let leftDelta = abs(block.bounds.minX - last.bounds.minX)

			let isContinuation = verticalGap >= -4 && verticalGap <= maxGap && leftDelta <= maxLeftDelta

			if isContinuation {
				let combinedLines = previousParagraph.lines + currentParagraph.lines
				let combinedText = combinedLines.map(\.text).joined(separator: "\n")
				let combinedBounds = last.bounds.union(block.bounds)
				let merged = DocumentBlock(bounds: combinedBounds, kind: .paragraph(.init(text: combinedText, lines: combinedLines)))
				result[result.count - 1] = merged
			} else {
				result.append(block)
			}
		}

		return result
	}

	private static func isInReadingOrder(_ lhs: CGRect, _ rhs: CGRect, pageBounds: CGRect) -> Bool {
		let lhsNormalized = normalize(lhs, in: pageBounds)
		let rhsNormalized = normalize(rhs, in: pageBounds)

		let verticalDelta = lhsNormalized.minY - rhsNormalized.minY
		let tolerance: CGFloat = 0.01

		if abs(verticalDelta) > tolerance {
			// Smaller Y should come first because the origin is at the top-left
			return verticalDelta < 0
		}

		return lhsNormalized.minX < rhsNormalized.minX
	}

	private static func orderIndex(for rect: CGRect, textLines: [DocumentBlock.TextLine], pageBounds: CGRect) -> Int {
		let normalizedRect = normalize(rect, in: pageBounds)
		for (index, line) in textLines.enumerated() {
			let normalizedLine = normalize(line.bounds, in: pageBounds)
			let center = CGPoint(x: normalizedRect.midX, y: normalizedRect.midY)
			if overlap(normalizedRect, normalizedLine) > 0.05 || normalizedLine.contains(center) {
				return index
			}
		}
		return Int.max
	}

	private static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
		let intersection = lhs.intersection(rhs)
		guard intersection.width > 0, intersection.height > 0 else { return 0 }
		let area = intersection.width * intersection.height
		let minArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
		return minArea > 0 ? area / minArea : 0
	}
}
