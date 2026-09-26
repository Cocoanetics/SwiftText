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
		// Only sizes that uniformly set a paragraph can define a heading level.
		// A large inline word in otherwise body-sized text is emphasis, not an
		// extra level that should push every real heading down the hierarchy.
		let candidates = blocks.compactMap { block -> CGFloat? in
			guard case .paragraph(let paragraph) = block.kind,
			      let size = Self.uniformFontSize(in: paragraph),
			      size >= body * Self.headingRatio else { return nil }
			return size.rounded(toNearest: Self.sizeTolerance)
		}
		headingSizes = Array(Set(candidates)).sorted(by: >)
	}

	/// The heading level for `size`, or nil when it is body text or smaller.
	func headingLevel(forSize size: CGFloat) -> Int? {
		let rounded = size.rounded(toNearest: Self.sizeTolerance)
		guard let index = headingSizes.firstIndex(where: { abs($0 - rounded) < 0.01 }) else { return nil }
		return Swift.min(index + 1, Self.deepestLevel)
	}

	/// The explicit or typography-derived heading level for a paragraph.
	///
	/// Keeping this decision beside the document-wide size scale lets both the
	/// semantic composer and the Markdown renderer apply the same boundary
	/// before either one joins adjacent paragraphs.
	func headingLevel(for paragraph: DocumentBlock.Paragraph) -> Int? {
		if let level = paragraph.headingLevel { return level }

		let lines = paragraph.lines
			.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		let text = lines.isEmpty
			? paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
			: lines.joined(separator: " ")
		guard !text.isEmpty else { return nil }

		let contentRuns = paragraph.lines.flatMap(\.runs)
			.filter { !$0.text.allSatisfy(\.isWhitespace) }
		let styles = contentRuns.compactMap(\.style)
		guard !styles.isEmpty, styles.count == contentRuns.count,
		      let first = styles.first else { return nil }

		if styles.allSatisfy({ abs($0.fontSize - first.fontSize) < Self.sizeTolerance }),
		   let level = headingLevel(forSize: first.fontSize) {
			return level
		}

		// At body size, a single all-bold source line can only be distinguished
		// from an emphasised sentence by its shape.
		guard lines.count == 1,
		      isUniformBoldBodyText(paragraph),
		      Self.isBoldHeadingShape(text) else { return nil }
		return boldHeadingLevel
	}

	/// Whether every styled character in `paragraph` is bold body text. Adjacent
	/// semantic blocks with this same typography may be two lines of one body
	/// paragraph, so the composer uses this before treating either line's shape
	/// as a structural heading boundary.
	func isUniformBoldBodyText(_ paragraph: DocumentBlock.Paragraph) -> Bool {
		guard let bodySize else { return false }
		let contentRuns = paragraph.lines.flatMap(\.runs)
			.filter { !$0.text.allSatisfy(\.isWhitespace) }
		let styles = contentRuns.compactMap(\.style)
		guard !styles.isEmpty, styles.count == contentRuns.count else { return false }
		return styles.allSatisfy {
			abs($0.fontSize - bodySize) < Self.sizeTolerance
				&& $0.isBold && !$0.isMonospaced
		}
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

	private static func uniformFontSize(in paragraph: DocumentBlock.Paragraph) -> CGFloat? {
		let contentRuns = paragraph.lines.flatMap(\.runs)
			.filter { !$0.text.allSatisfy(\.isWhitespace) }
		let styles = contentRuns.compactMap(\.style)
		guard !styles.isEmpty, styles.count == contentRuns.count,
		      let first = styles.first,
		      styles.allSatisfy({ abs($0.fontSize - first.fontSize) < sizeTolerance })
		else { return nil }
		return first.fontSize
	}
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
