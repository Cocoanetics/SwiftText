//
//  TextLineSemanticComposer.swift
//  SwiftTextOCR
//
//  Created by OpenAI Codex on 20.12.24.
//

import CoreGraphics
import Foundation

/// Groups OCR text lines into the semantic structure provided by Vision.
public enum TextLineSemanticComposer {
	public static func composeBlocks(
		from textLines: [TextLine],
		semantics: DocumentSemantics,
		layoutSize: CGSize
	) -> [DocumentBlock] {
		guard layoutSize.width > 0, layoutSize.height > 0 else {
			return semantics.blocks.map(\.block)
		}
		
		let lineInfos = makeLineInfos(
			from: textLines,
			layoutSize: layoutSize,
			referenceSize: semantics.referenceSize
		)
		
		var assigned = Set<Int>()
		var blocks = [DocumentBlock]()
		var metadata = [BlockMetadata]()
		
		for semanticBlock in semantics.blocks {
			let result = composeBlock(
				from: semanticBlock,
				lineInfos: lineInfos,
				assignedLines: &assigned,
				referenceSize: semantics.referenceSize
			)
			guard let block = result.block, let context = result.metadata else { continue }
			blocks.append(block)
			metadata.append(context)
		}
		
		let remaining = lineInfos.filter { !assigned.contains($0.id) }
		let appended = appendRemainingLines(
			remaining,
			to: &blocks,
			metadata: &metadata,
			layoutSize: layoutSize,
			referenceSize: semantics.referenceSize
		)
		
		let newParagraphs = appended.filter { !$0.assigned }.map {
			makeStandaloneParagraph(from: $0.info, referenceSize: semantics.referenceSize)
		}
		
		blocks.append(contentsOf: newParagraphs.map(\.block))
		metadata.append(contentsOf: newParagraphs.map(\.metadata))
		
		let (orderedBlocks, orderedMetadata) = sortBlocksWithMetadata(blocks, metadata: metadata)
		let (splitBlocks, splitMetadata) = splitParagraphBlocks(
			orderedBlocks,
			metadata: orderedMetadata,
			referenceSize: semantics.referenceSize
		)
		let (mergedBlocks, _) = mergeParagraphBlocks(
			splitBlocks,
			metadata: splitMetadata,
			referenceSize: semantics.referenceSize
		)
		return mergedBlocks
	}
}

// MARK: - Composition Helpers

private struct LineInfo {
	let id: Int
	let text: String
	let normalizedBounds: NormalizedRect
	let semanticBounds: CGRect
	let actualBounds: CGRect
}

private struct BlockMetadata {
	var normalizedBounds: NormalizedRect
}

private func makeLineInfos(
	from lines: [TextLine],
	layoutSize: CGSize,
	referenceSize: CGSize
) -> [LineInfo] {
	var results = [LineInfo]()
	
	for (index, line) in lines.enumerated() {
		let fragments = line.fragments
		guard let first = fragments.first else { continue }
		let bounds = fragments.reduce(first.bounds) { $0.union($1.bounds) }
		guard bounds.width > 0, bounds.height > 0 else { continue }
		
		let normalized = bounds.normalized(in: layoutSize)
		let semanticBounds = normalized.scaled(to: referenceSize)
		let text = line.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { continue }
		
		results.append(
			LineInfo(
				id: index,
				text: text,
				normalizedBounds: normalized,
				semanticBounds: semanticBounds,
				actualBounds: bounds
			)
		)
	}
	
	return results
}

private func composeBlock(
	from semanticBlock: NormalizedDocumentBlock,
	lineInfos: [LineInfo],
	assignedLines: inout Set<Int>,
	referenceSize: CGSize
) -> (block: DocumentBlock?, metadata: BlockMetadata?) {
	let normalizedBounds = semanticBlock.normalizedBounds
	let block: DocumentBlock
	let metadataBounds: NormalizedRect
	switch semanticBlock.block.kind {
	case .paragraph:
		let matched = consumeLines(
			in: normalizedBounds,
			lineInfos: lineInfos,
			assigned: &assignedLines
		)
		guard !matched.isEmpty else {
			return (nil, nil)
		}
		
		let finalLines = makeDocumentLines(from: matched)
		let text = finalLines.map(\.text).joined(separator: "\n")
		let updated = DocumentBlock.Paragraph(text: text, lines: finalLines)
		let resolvedBounds = unionRect(
			matched.map(\.semanticBounds),
			fallback: semanticBlock.block.bounds
		)
		block = DocumentBlock(bounds: resolvedBounds, kind: .paragraph(updated))
		metadataBounds = unionNormalizedRect(
			matched.map(\.normalizedBounds),
			fallback: normalizedBounds
		)
		
	case .list(let list):
		var items = [DocumentBlock.List.Item]()
		for (index, item) in list.items.enumerated() {
			let normalizedItem = semanticBlock.listItems.indices.contains(index)
				? semanticBlock.listItems[index].normalizedBounds
				: item.bounds.normalized(in: referenceSize)
			let itemMatches = consumeLines(
				in: normalizedItem,
				lineInfos: lineInfos,
				assigned: &assignedLines
			)
			let finalLines = itemMatches.isEmpty ? item.lines : makeDocumentLines(from: itemMatches)
			let text = finalLines.map(\.text).joined(separator: "\n")
			items.append(
				DocumentBlock.List.Item(
					text: text,
					markerString: item.markerString,
					bounds: item.bounds,
					lines: finalLines
				)
			)
		}
		let updated = DocumentBlock.List(marker: list.marker, items: items)
		block = DocumentBlock(bounds: semanticBlock.block.bounds, kind: .list(updated))
		metadataBounds = normalizedBounds
		
	case .table(let table):
		var rows = [[DocumentBlock.Table.Cell]]()
		for (rowIndex, row) in table.rows.enumerated() {
			var newRow = [DocumentBlock.Table.Cell]()
			for (columnIndex, cell) in row.enumerated() {
				let normalizedCell = semanticBlock.tableRows.indices.contains(rowIndex) && semanticBlock.tableRows[rowIndex].indices.contains(columnIndex)
					? semanticBlock.tableRows[rowIndex][columnIndex].normalizedBounds
					: cell.bounds.normalized(in: referenceSize)
				let cellMatches = consumeLines(
					in: normalizedCell,
					lineInfos: lineInfos,
					assigned: &assignedLines
				)
				let finalLines = cellMatches.isEmpty ? cell.lines : makeDocumentLines(from: cellMatches)
				let text = finalLines.map(\.text).joined(separator: "\n")
				newRow.append(
					DocumentBlock.Table.Cell(
						rowRange: cell.rowRange,
						columnRange: cell.columnRange,
						text: text,
						bounds: cell.bounds,
						lines: finalLines
					)
				)
			}
			rows.append(newRow)
		}
		let updated = DocumentBlock.Table(rows: rows)
		block = DocumentBlock(bounds: semanticBlock.block.bounds, kind: .table(updated))
		metadataBounds = normalizedBounds
		
	case .image(let image):
		block = DocumentBlock(bounds: semanticBlock.block.bounds, kind: .image(image))
		metadataBounds = normalizedBounds
	}
	
	return (block, BlockMetadata(normalizedBounds: metadataBounds))
}

private func unionRect(_ rects: [CGRect], fallback: CGRect) -> CGRect {
	let unioned = rects.reduce(into: CGRect.null) { partial, rect in
		partial = partial.union(rect)
	}
	return unioned.isNull ? fallback : unioned
}

private func unionNormalizedRect(_ rects: [NormalizedRect], fallback: NormalizedRect) -> NormalizedRect {
	guard var unioned = rects.first else {
		return fallback
	}
	for rect in rects.dropFirst() {
		unioned = unioned.union(rect)
	}
	return unioned
}

private func mergeParagraphBlocks(
	_ blocks: [DocumentBlock],
	metadata: [BlockMetadata],
	referenceSize: CGSize
) -> ([DocumentBlock], [BlockMetadata]) {
	guard !blocks.isEmpty else { return (blocks, metadata) }
	var mergedBlocks: [DocumentBlock] = []
	var mergedMetadata: [BlockMetadata] = []
	
	for (block, meta) in zip(blocks, metadata) {
		guard case .paragraph(let currentParagraph) = block.kind else {
			mergedBlocks.append(block)
			mergedMetadata.append(meta)
			continue
		}
		
		if let lastIndex = mergedBlocks.indices.last,
		   case .paragraph(let previousParagraph) = mergedBlocks[lastIndex].kind,
		   shouldMergeParagraphs(
			previous: previousParagraph,
			previousBounds: mergedBlocks[lastIndex].bounds,
			previousMetadata: mergedMetadata[lastIndex],
			current: currentParagraph,
			currentBounds: block.bounds,
			currentMetadata: meta,
			referenceSize: referenceSize
		   ) {
			let combinedLines = previousParagraph.lines + currentParagraph.lines
			let combinedText = combinedLines.map(\.text).joined(separator: "\n")
			let combinedBounds = mergedBlocks[lastIndex].bounds.union(block.bounds)
			let mergedParagraph = DocumentBlock(bounds: combinedBounds, kind: .paragraph(.init(text: combinedText, lines: combinedLines)))
			mergedBlocks[lastIndex] = mergedParagraph
			
			let newNormalized = mergedMetadata[lastIndex].normalizedBounds.union(meta.normalizedBounds)
			mergedMetadata[lastIndex].normalizedBounds = newNormalized
			continue
		}
		
		mergedBlocks.append(block)
		mergedMetadata.append(meta)
	}
	
	return (mergedBlocks, mergedMetadata)
}

private func splitParagraphBlocks(
	_ blocks: [DocumentBlock],
	metadata: [BlockMetadata],
	referenceSize: CGSize
) -> ([DocumentBlock], [BlockMetadata]) {
	guard !blocks.isEmpty else { return (blocks, metadata) }
	var resultBlocks: [DocumentBlock] = []
	var resultMetadata: [BlockMetadata] = []
	
	for (block, meta) in zip(blocks, metadata) {
		guard case .paragraph(let paragraph) = block.kind else {
			resultBlocks.append(block)
			resultMetadata.append(meta)
			continue
		}
		
		let segments = splitParagraphSegment(
			paragraph: paragraph,
			referenceBounds: block.bounds,
			originalMetadata: meta,
			referenceSize: referenceSize
		)
		if segments.count <= 1 {
			resultBlocks.append(block)
			resultMetadata.append(meta)
		} else {
			resultBlocks.append(contentsOf: segments.map(\.block))
			resultMetadata.append(contentsOf: segments.map(\.metadata))
		}
	}
	
	return (resultBlocks, resultMetadata)
}

private func splitParagraphSegment(
	paragraph: DocumentBlock.Paragraph,
	referenceBounds: CGRect,
	originalMetadata: BlockMetadata,
	referenceSize: CGSize
) -> [(block: DocumentBlock, metadata: BlockMetadata)] {
	let lines = paragraph.lines
	guard lines.count > 1 else {
		return [(DocumentBlock(bounds: referenceBounds, kind: .paragraph(paragraph)), originalMetadata)]
	}
	
	var segments = [[DocumentBlock.TextLine]]()
	var current = [DocumentBlock.TextLine]()
	let minGap: CGFloat = 16
	let ratio: CGFloat = 0.8
	
	for line in lines {
		if let previous = current.last {
			let gap = line.bounds.minY - previous.bounds.maxY
			let maxHeight = max(previous.bounds.height, line.bounds.height)
			let shouldSplit = gap > max(maxHeight * ratio, minGap)
			if shouldSplit && !current.isEmpty {
				segments.append(current)
				current = []
			}
		}
		current.append(line)
	}
	
	if !current.isEmpty {
		segments.append(current)
	}
	
	if segments.count <= 1 {
		return [(DocumentBlock(bounds: referenceBounds, kind: .paragraph(paragraph)), originalMetadata)]
	}
	
	return segments.map { segment in
		let unionRect = segment.reduce(into: CGRect.null) { partial, line in
			partial = partial.union(line.bounds)
		}
		let bounds = unionRect.isNull ? referenceBounds : unionRect
		let text = segment.map(\.text).joined(separator: "\n")
		let paragraph = DocumentBlock.Paragraph(text: text, lines: segment)
		let block = DocumentBlock(bounds: bounds, kind: .paragraph(paragraph))
		let normalized = bounds.normalized(in: referenceSize)
		return (block, BlockMetadata(normalizedBounds: normalized))
	}
}

private func shouldMergeParagraphs(
	previous: DocumentBlock.Paragraph,
	previousBounds: CGRect,
	previousMetadata: BlockMetadata,
	current: DocumentBlock.Paragraph,
	currentBounds: CGRect,
	currentMetadata: BlockMetadata,
	referenceSize: CGSize
) -> Bool {
	if shouldPreventMerge(previous: previous, current: current) {
		return false
	}
	
	let lastLine = previous.lines.last
	let firstLine = current.lines.first
	
	let lineGap: CGFloat
	if let lastLine, let firstLine {
		lineGap = firstLine.bounds.minY - lastLine.bounds.maxY
	} else {
		lineGap = currentBounds.minY - previousBounds.maxY
	}
	
	let lowerLineHeight = min(
		lastLine?.bounds.height ?? previousBounds.height,
		firstLine?.bounds.height ?? currentBounds.height
	)
	let allowedGap = max(min(lowerLineHeight * 0.9, lowerLineHeight + 6), 3)
	let overlapAllowance = -max(lowerLineHeight * 0.6, 2)
	let leftDeltaNormalized = abs(currentMetadata.normalizedBounds.minX - previousMetadata.normalizedBounds.minX)
	let maxLeftDeltaNormalized = max(0.015, 4 / max(referenceSize.width, 1))
	return lineGap >= overlapAllowance && lineGap <= allowedGap && leftDeltaNormalized <= maxLeftDeltaNormalized
}

private func shouldPreventMerge(
	previous: DocumentBlock.Paragraph,
	current: DocumentBlock.Paragraph
) -> Bool {
	let candidates = [previous.text, current.text]
	return candidates.contains { text in
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return isLikelyHeading(trimmed)
	}
}

private func isLikelyHeading(_ text: String) -> Bool {
	let firstLine = text.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? text
	guard firstLine.hasSuffix(":") else {
		return false
	}
	let heading = firstLine.dropLast()
	guard heading.count <= 30, let first = heading.first else {
		return false
	}
	return first.isUppercase
}

private func consumeLines(
	in normalizedBounds: NormalizedRect,
	lineInfos: [LineInfo],
	assigned: inout Set<Int>
) -> [LineInfo] {
	let tolerance = max(normalizedBounds.height * 0.15, 0.01)
	var matches = [LineInfo]()
	
	for info in lineInfos where !assigned.contains(info.id) {
		let center = info.normalizedBounds.center
		let verticallyAligned = center.y >= normalizedBounds.minY - tolerance &&
			center.y <= normalizedBounds.maxY + tolerance
		let horizontallyAligned = info.normalizedBounds.maxX >= normalizedBounds.minX - tolerance &&
			info.normalizedBounds.minX <= normalizedBounds.maxX + tolerance
		
		if verticallyAligned && horizontallyAligned {
			assigned.insert(info.id)
			matches.append(info)
		}
	}
	
	return matches.sorted { lhs, rhs in
		if abs(lhs.semanticBounds.minY - rhs.semanticBounds.minY) > 1 {
			return lhs.semanticBounds.minY < rhs.semanticBounds.minY
		}
		return lhs.semanticBounds.minX < rhs.semanticBounds.minX
	}
}

private func makeDocumentLines(from infos: [LineInfo]) -> [DocumentBlock.TextLine] {
	infos.map { info in
		DocumentBlock.TextLine(text: info.text, bounds: info.semanticBounds)
	}
}

private struct RemainingLine {
	let info: LineInfo
	var assigned = false
}

private func appendRemainingLines(
	_ remaining: [LineInfo],
	to blocks: inout [DocumentBlock],
	metadata: inout [BlockMetadata],
	layoutSize: CGSize,
	referenceSize: CGSize
) -> [RemainingLine] {
	guard !remaining.isEmpty else { return [] }
	
	var leftovers = remaining.map { RemainingLine(info: $0) }
	
	for index in leftovers.indices {
		let line = leftovers[index].info
		let candidates = blocks.enumerated().compactMap { idx, block -> (Int, CGRect)? in
			guard case .paragraph = block.kind else { return nil }
			let normalized = metadata[idx].normalizedBounds
			let rect = normalized.scaled(to: layoutSize)
			guard rect.maxY <= line.actualBounds.minY + line.actualBounds.height else { return nil }
			return (idx, rect)
		}
		
		guard let target = candidates.min(by: { lhs, rhs in
			let lhsDistance = max(0, line.actualBounds.minY - lhs.1.maxY)
			let rhsDistance = max(0, line.actualBounds.minY - rhs.1.maxY)
			return lhsDistance < rhsDistance
		}) else {
			continue
		}
		
		let distance = max(0, line.actualBounds.minY - target.1.maxY)
		if distance <= (line.actualBounds.height * 0.5) {
			append(line: line, to: target.0, blocks: &blocks, metadata: &metadata, referenceSize: referenceSize)
			leftovers[index].assigned = true
		}
	}
	
	return leftovers
}

private func append(
	line: LineInfo,
	to index: Int,
	blocks: inout [DocumentBlock],
	metadata: inout [BlockMetadata],
	referenceSize: CGSize
) {
	guard case .paragraph(let paragraph) = blocks[index].kind else { return }
	var newLines = paragraph.lines
	newLines.append(DocumentBlock.TextLine(text: line.text, bounds: line.semanticBounds))
	let text = newLines.map(\.text).joined(separator: "\n")
	let normalizedUnion = metadata[index].normalizedBounds.union(line.normalizedBounds)
	let updatedBounds = normalizedUnion.scaled(to: referenceSize)
	let updated = DocumentBlock(bounds: updatedBounds, kind: .paragraph(.init(text: text, lines: newLines)))
	blocks[index] = updated
	metadata[index].normalizedBounds = normalizedUnion
}

private func makeStandaloneParagraph(
	from line: LineInfo,
	referenceSize: CGSize
) -> (block: DocumentBlock, metadata: BlockMetadata) {
	let normalized = line.normalizedBounds
	let bounds = normalized.scaled(to: referenceSize)
	let docLine = DocumentBlock.TextLine(text: line.text, bounds: line.semanticBounds)
	let paragraph = DocumentBlock.Paragraph(text: line.text, lines: [docLine])
	let block = DocumentBlock(bounds: bounds, kind: .paragraph(paragraph))
	let meta = BlockMetadata(normalizedBounds: normalized)
	return (block, meta)
}

private func sortBlocksWithMetadata(
	_ blocks: [DocumentBlock],
	metadata: [BlockMetadata]
) -> ([DocumentBlock], [BlockMetadata]) {
	let combined = zip(blocks, metadata)
		.enumerated()
		.map { index, pair in (index: index, block: pair.0, metadata: pair.1) }
		.sorted { lhs, rhs in
			let lhsBounds = lhs.metadata.normalizedBounds
			let rhsBounds = rhs.metadata.normalizedBounds
			
			if abs(lhsBounds.minY - rhsBounds.minY) > 0.01 {
				return lhsBounds.minY < rhsBounds.minY
			}
			return lhsBounds.minX < rhsBounds.minX
		}
	let sortedBlocks = combined.map(\.block)
	let sortedMetadata = combined.map(\.metadata)
	return (sortedBlocks, sortedMetadata)
}
