//
//  TextColumns.swift
//  SwiftTextOCR
//
//  Where the lines of a page's columns of text end.
//

import CoreGraphics
import Foundation

/// Where a column of text ends, so that a line which stopped early can be told
/// from one that ran out of room.
///
/// Only a line known to have wrapped shows where its column ends: every line
/// of a paragraph except the last. Such a line counts toward a column when it
/// starts at the same left edge and is set at the same size as the line in
/// question, so a title or banner that merely shares the left edge does not
/// widen the column, and when it ends before any text standing beside the
/// line in question — the next column over. Without such evidence, a column is
/// only as wide as the lines being compared.
struct TextColumns {
	private struct Extent {
		let bounds: CGRect
		let fontSize: CGFloat?
		let wrapped: Bool
	}

	private let extents: [Extent]
	/// How far apart two left edges may be and still start the same column.
	private let tolerance: CGFloat

	init(blocks: [DocumentBlock], tolerance: CGFloat) {
		self.tolerance = tolerance
		extents = blocks.flatMap { block -> [Extent] in
			guard case .paragraph(let paragraph) = block.kind else { return [] }
			return paragraph.lines.enumerated().map { index, line in
				Extent(
					bounds: line.bounds,
					fontSize: line.uniformFontSize,
					wrapped: index < paragraph.lines.count - 1)
			}
		}
	}

	/// Whether `next` begins where `line` ran out of room: its first word would
	/// not have fitted at the end of `line`.
	///
	/// A line breaker moves a word down only when it does not fit, so a line
	/// that could have taken the next word was ended on purpose, the way a
	/// heading or a paragraph ends.
	func wraps(from line: DocumentBlock.TextLine, to next: DocumentBlock.TextLine) -> Bool {
		let nextText = next.text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !nextText.isEmpty, next.bounds.width > 0 else { return false }
		// Both lines exist in this column, so it is at least as wide as either.
		let right = max(rightEdge(of: line), next.bounds.maxX)
		// Set in the same face, the next line's average advance estimates what
		// its first word, and the space before it, needs.
		let advance = next.bounds.width / CGFloat(nextText.count)
		let firstWord = nextText.prefix { !$0.isWhitespace }
		return line.bounds.maxX + CGFloat(firstWord.count + 1) * advance > right
	}

	/// How far the column that `line` belongs to runs.
	private func rightEdge(of line: DocumentBlock.TextLine) -> CGFloat {
		// Text beside the line starts the next column. A line running past
		// where that text starts cannot belong to this column, even if it
		// shares the left edge — a full-width passage above a two-column page.
		let beside = extents
			.filter {
				$0.bounds.minX > line.bounds.maxX
					&& $0.bounds.minY < line.bounds.maxY && $0.bounds.maxY > line.bounds.minY
			}
			.map(\.bounds.minX)
			.min()
		let size = line.uniformFontSize
		var edge = line.bounds.maxX
		for extent in extents where extent.wrapped
			&& abs(extent.bounds.minX - line.bounds.minX) <= tolerance
			&& Self.sizesMatch(extent.fontSize, size)
			&& extent.bounds.maxX <= (beside ?? .infinity) {
			edge = max(edge, extent.bounds.maxX)
		}
		return edge
	}

	private static func sizesMatch(_ lhs: CGFloat?, _ rhs: CGFloat?) -> Bool {
		guard let lhs, let rhs else { return lhs == nil && rhs == nil }
		return abs(lhs - rhs) < 0.5
	}
}

extension DocumentBlock.TextLine {
	/// The size every visible character of the line is set at, or nil when the
	/// line carries no style or mixes sizes.
	var uniformFontSize: CGFloat? {
		let styles = runs.filter { !$0.text.allSatisfy(\.isWhitespace) }.map(\.style)
		guard let first = styles.first, let size = first?.fontSize,
		      styles.allSatisfy({ $0.map { abs($0.fontSize - size) < 0.5 } ?? false })
		else { return nil }
		return size
	}
}
