//
//  TextStyle.swift
//  SwiftTextOCR
//
//  The typographic identity of a run of text, as read from a page.
//

import CoreGraphics
import Foundation

/// How a run of text is set: its size, and whether it is bold, italic or
/// monospaced.
///
/// A PDF's text layer carries this per character, which is what makes emphasis
/// and headings recoverable from a page that has one. OCR does not: it reports
/// characters and geometry, so text recognised from an image has no style and
/// the runs stay empty.
public struct TextStyle: Equatable, Sendable {
	/// The font's point size, in the page's own coordinate space.
	public let fontSize: CGFloat
	public let isBold: Bool
	public let isItalic: Bool
	public let isMonospaced: Bool

	public init(fontSize: CGFloat, isBold: Bool = false, isItalic: Bool = false, isMonospaced: Bool = false) {
		self.fontSize = fontSize
		self.isBold = isBold
		self.isItalic = isItalic
		self.isMonospaced = isMonospaced
	}

	/// Whether two runs are set the same way, so they can be written as one.
	/// Sizes within a twentieth of a point count as equal — a page's own
	/// rounding should not split a run in two.
	public func matches(_ other: TextStyle) -> Bool {
		abs(fontSize - other.fontSize) < 0.05
			&& isBold == other.isBold
			&& isItalic == other.isItalic
			&& isMonospaced == other.isMonospaced
	}
}

/// A run of text set one way.
public struct StyleRun: Equatable, Sendable {
	public let text: String
	/// The run's style, or nil where the source cannot report one (OCR).
	public let style: TextStyle?

	public init(text: String, style: TextStyle?) {
		self.text = text
		self.style = style
	}
}

public extension Array where Element == StyleRun {
	/// The runs' text, which is the text they cover.
	var text: String { map(\.text).joined() }

	/// The same runs with adjacent equally-styled ones merged, and empty ones
	/// dropped. Reading a page tends to produce many short runs; a reader of
	/// the result wants the longest ones it can have.
	func coalesced() -> [StyleRun] {
		var result: [StyleRun] = []
		for run in self where !run.text.isEmpty {
			if let last = result.last, styleMatches(last.style, run.style) {
				result[result.count - 1] = StyleRun(text: last.text + run.text, style: last.style)
			} else {
				result.append(run)
			}
		}
		return result
	}

	/// The same runs with whitespace trimmed from both ends, provided what
	/// remains is exactly `text`.
	///
	/// Line text is trimmed after it is read, and runs that no longer cover it
	/// would put emphasis around the wrong words. Rather than risk that, a
	/// mismatch gives up the style for the line and leaves the text plain.
	func trimmedToMatch(_ text: String) -> [StyleRun] {
		guard !isEmpty else { return [] }
		var runs = self
		while let first = runs.first {
			let remainder = first.text.drop { $0.isWhitespace }
			if remainder.isEmpty { runs.removeFirst() } else if remainder.count != first.text.count {
				runs[0] = StyleRun(text: String(remainder), style: first.style)
				break
			} else { break }
		}
		while let last = runs.last {
			let remainder = last.text.reversed().drop { $0.isWhitespace }.reversed()
			if remainder.isEmpty { runs.removeLast() } else if remainder.count != last.text.count {
				runs[runs.count - 1] = StyleRun(text: String(remainder), style: last.style)
				break
			} else { break }
		}
		return runs.text == text ? runs : []
	}

	/// The runs covering `self`'s text with `prefix` removed from the front.
	/// Used where text is edited after it was read — stripping a list marker —
	/// so that the runs keep covering exactly the text that remains.
	func removingPrefix(_ prefix: String) -> [StyleRun] {
		guard !prefix.isEmpty else { return self }
		var remaining = prefix.count
		var result: [StyleRun] = []
		for run in self {
			guard remaining > 0 else { result.append(run); continue }
			if run.text.count <= remaining {
				remaining -= run.text.count
			} else {
				result.append(StyleRun(text: String(run.text.dropFirst(remaining)), style: run.style))
				remaining = 0
			}
		}
		return result
	}
}

private func styleMatches(_ lhs: TextStyle?, _ rhs: TextStyle?) -> Bool {
	switch (lhs, rhs) {
	case (nil, nil): return true
	case (let lhs?, let rhs?): return lhs.matches(rhs)
	default: return false
	}
}
