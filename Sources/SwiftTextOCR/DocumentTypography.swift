//
//  DocumentTypography.swift
//  SwiftTextOCR
//
//  Recovering a document's structure from how its text is set.
//

import CoreGraphics
import Foundation

/// What the sizes on a page mean: which one is body text, and which of the
/// larger ones stand for which heading level.
///
/// A page does not say "this is a heading" — it says "this is 22pt" — so the
/// levels are read from the document as a whole. Body text is whichever size
/// sets the most characters, which on any ordinary document is the running
/// text by a wide margin. Every distinctly larger size is then a heading
/// level, deepest-first, so a document's own scale decides the levels rather
/// than a table of point sizes this code could not know.
struct DocumentTypography {
	/// The size that sets the body text, or nil when nothing carries style.
	let bodySize: CGFloat?
	/// Heading sizes, largest first; their positions are levels 1, 2, 3…
	private let headingSizes: [CGFloat]

	/// A size must exceed body by this much to read as a heading rather than as
	/// the same text with a different face — enough to clear a document's own
	/// rounding, and well under the smallest step a type scale uses.
	private static let headingRatio: CGFloat = 1.08
	/// Sizes closer together than this are the same size wearing two names.
	private static let sizeTolerance: CGFloat = 0.5
	/// Markdown has six levels; a document with more distinct sizes flattens
	/// into the deepest.
	private static let deepestLevel = 6

	init(blocks: [DocumentBlock]) {
		var charactersPerSize: [CGFloat: Int] = [:]
		for run in blocks.flatMap(\.styleRuns) {
			guard let style = run.style else { continue }
			let characters = run.text.filter { !$0.isWhitespace }.count
			guard characters > 0 else { continue }
			charactersPerSize[style.fontSize.rounded(toNearest: Self.sizeTolerance), default: 0] += characters
		}
		guard let body = charactersPerSize.max(by: { lhs, rhs in
			// Most characters wins; on a tie the smaller size, since body text is
			// what a document has most of and headings are the exception.
			lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
		})?.key else {
			bodySize = nil
			headingSizes = []
			return
		}
		bodySize = body
		headingSizes = charactersPerSize.keys
			.filter { $0 >= body * Self.headingRatio }
			.sorted(by: >)
	}

	/// The heading level for `size`, or nil when it is body text or smaller.
	func headingLevel(forSize size: CGFloat) -> Int? {
		let rounded = size.rounded(toNearest: Self.sizeTolerance)
		guard let index = headingSizes.firstIndex(where: { abs($0 - rounded) < 0.01 }) else { return nil }
		return Swift.min(index + 1, Self.deepestLevel)
	}

	/// The level a heading gets when it is set at body size and can only be
	/// recognised by being bold — one below every size-distinguished level.
	///
	/// A stylesheet often stops scaling at the deeper levels: `h4` may be bold
	/// body text, identical in the page to a bold sentence. Those are told
	/// apart by shape rather than by size — see ``isBoldHeadingShape(_:)``.
	var boldHeadingLevel: Int {
		Swift.min(headingSizes.count + 1, Self.deepestLevel)
	}

	/// Whether an all-bold body-size paragraph reads as a heading rather than
	/// as an emphasised sentence.
	///
	/// A heading is a label, not a statement: it is short, stands alone, and
	/// does not end in sentence punctuation. `Ein komplett fetter Absatz.` ends
	/// in a period and stays a paragraph; `Vierte Ebene` does not and becomes a
	/// heading. Nothing in the page distinguishes them, so this is a judgement
	/// about what the author meant, and it is deliberately conservative.
	static func isBoldHeadingShape(_ text: String) -> Bool {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, !trimmed.contains("\n") else { return false }
		guard let last = trimmed.last, !sentenceEndings.contains(last) else { return false }
		return trimmed.count <= maximumHeadingCharacters
			&& trimmed.split(separator: " ").count <= maximumHeadingWords
	}

	/// Punctuation that ends a statement. A heading rarely carries any of it.
	private static let sentenceEndings: Set<Character> = [".", "!", "?", ";", ",", ":"]
	private static let maximumHeadingCharacters = 80
	private static let maximumHeadingWords = 12
}

extension DocumentBlock {
	/// Every style run this block's text is made of.
	var styleRuns: [StyleRun] {
		switch kind {
		case .paragraph(let paragraph): return paragraph.lines.flatMap(\.runs)
		case .list(let list): return list.items.flatMap { $0.lines.flatMap(\.runs) }
		case .table, .image: return []
		}
	}
}

private extension CGFloat {
	func rounded(toNearest step: CGFloat) -> CGFloat {
		guard step > 0 else { return self }
		return (self / step).rounded() * step
	}
}
