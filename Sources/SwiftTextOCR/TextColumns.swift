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
/// question — so a title or banner that merely shares the left edge does not
/// widen the column — and when it ends before any text standing beside that
/// line, the next column over. Columns of different widths can still share a
/// left edge, as a full-width passage does with the left column of the page
/// below it, and of those a line belongs to the narrowest that holds it.
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

	/// Whether `next` continues `line` as the next line of the same paragraph.
	///
	/// A line breaker moves a word down only when it does not fit, so a line
	/// that could have taken the next word was ended on purpose, the way a
	/// heading or a paragraph ends. Deciding that needs the column's width;
	/// where no line shows it, only the text can: a line ending in a hyphen, or
	/// a next line going on in lower case, continues a sentence.
	func wraps(from line: DocumentBlock.TextLine, to next: DocumentBlock.TextLine) -> Bool {
		let lineText = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
		let nextText = next.text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !lineText.isEmpty, !nextText.isEmpty else { return false }
		if next.bounds.width > 0 {
			// Set in the same face, the next line's average advance estimates
			// what its first word, and the space before it, needs.
			let advance = next.bounds.width / CGFloat(nextText.count)
			let firstWord = nextText.prefix { !$0.isWhitespace }
			if let edge = columnEdge(of: line, slack: 10 * advance) {
				return line.bounds.maxX + CGFloat(firstWord.count + 1) * advance > edge
			}
		}
		return lineText.hasSuffix("-") || nextText.first?.isLowercase == true
	}

	/// Where the column that `line` belongs to ends, or nil when no line shows
	/// it. A wrapped line ends within a word of its column's edge, so of the
	/// edges at least as far out as `line`, less that `slack`, the nearest one
	/// is its column's.
	private func columnEdge(of line: DocumentBlock.TextLine, slack: CGFloat) -> CGFloat? {
		let beside = extents
			.filter {
				$0.bounds.minX > line.bounds.maxX
					&& $0.bounds.minY < line.bounds.maxY && $0.bounds.maxY > line.bounds.minY
			}
			.map(\.bounds.minX)
			.min()
		let size = line.uniformFontSize
		let edge = extents
			.filter {
				$0.wrapped
					&& abs($0.bounds.minX - line.bounds.minX) <= tolerance
					&& Self.sizesMatch($0.fontSize, size)
					&& $0.bounds.maxX <= (beside ?? .infinity)
					&& $0.bounds.maxX >= line.bounds.maxX - slack
			}
			.map(\.bounds.maxX)
			.min()
		return edge.map { max($0, line.bounds.maxX) }
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
