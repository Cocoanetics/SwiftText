//
//  TextLine.swift
//  SwiftTextPDF
//
//  Created by Oliver Drobnik on 05.12.24.
//

import Foundation

/// Represents a single line of text composed of multiple text fragments.
public struct TextLine {
	/// The text fragments that make up the line.
	public var fragments: [TextFragment]

	/// The line's text, with each pair of fragments joined by what the space
	/// between them means.
	///
	/// A fragment boundary is not always the same thing. A reader splits a line
	/// where a gap is wide enough to be structural — the space between two table
	/// columns — and that keeps its tab. But the OCR reader also splits a line
	/// into its individual words, to give each one its own bounds, and those
	/// fragments meet exactly where a single space stood. Joining *those* with a
	/// tab put one inside every OCR'd heading: `Zweite\tEbene`.
	public var combinedText: String {
		var result = ""
		for (index, fragment) in fragments.enumerated() {
			if index > 0 { result += Self.separator(between: fragments[index - 1], and: fragment) }
			result += fragment.string
		}
		return result
	}

	/// What stood between two fragments of one line: a tab where the gap is too
	/// wide to be a word space, otherwise the space itself.
	static func separator(between previous: TextFragment, and next: TextFragment) -> String {
		let height = Swift.max((previous.bounds.height + next.bounds.height) / 2, 1)
		let gap = next.bounds.minX - previous.bounds.maxX
		// A word space runs to about a third of the type size; anything past
		// half of it is a gap someone put there on purpose.
		return gap > Swift.max(height * 0.6, 4) ? "\t" : " "
	}

	/// ``combinedText`` split into runs by how each part is set, empty when no
	/// fragment carries style. Whatever joins two fragments takes the style of
	/// the fragment it follows, so the runs cover ``combinedText`` exactly.
	public var styleRuns: [StyleRun] {
		guard fragments.contains(where: { !$0.styleRuns.isEmpty }) else { return [] }
		var result: [StyleRun] = []
		for (index, fragment) in fragments.enumerated() {
			if index > 0 {
				result.append(StyleRun(
					text: Self.separator(between: fragments[index - 1], and: fragment),
					style: result.last?.style))
			}
			if fragment.styleRuns.isEmpty {
				result.append(StyleRun(text: fragment.string, style: nil))
			} else {
				result.append(contentsOf: fragment.styleRuns)
			}
		}
		return result.coalesced()
	}

	/// The vertical position of the line, determined by the first fragment's minimum Y coordinate.
	public var yPosition: CGFloat {
		fragments.first?.bounds.minY ?? 0
	}
}

/// Represents a fragment of text within a PDF page, including its string and bounding rectangle.
public struct TextFragment {
	/// The bounding rectangle of the text fragment within the page.
	public let bounds: CGRect

	/// The textual content of the fragment.
	public let string: String

	/// How the parts of ``string`` are set, covering it exactly. Empty when the
	/// source cannot report style, as OCR cannot.
	public let styleRuns: [StyleRun]

	/// Creates a text fragment with a bounding rectangle and string value.
	public init(bounds: CGRect, string: String, styleRuns: [StyleRun] = []) {
		self.bounds = bounds
		self.string = string
		self.styleRuns = styleRuns
	}
}

extension Sequence where Element == TextFragment {
	public func assembledLines(
		splitVerticalFragments: Bool = false,
		verticalAspectRatioThreshold: CGFloat = 2.0,
		verticalHeightMultiplier: CGFloat = 1.5
	) -> [TextLine] {

		let fragmentsArray = Array(self)
		let positiveHeights = fragmentsArray
			.map { Swift.max($0.bounds.height, 0) }
			.filter { $0 > 0 }
			.sorted()
		let typicalHeight = positiveHeights.isEmpty ? 0 : positiveHeights[positiveHeights.count / 2]

		var verticalFragments = [TextFragment]()
		var horizontalFragments = [TextFragment]()

		for fragment in fragmentsArray {
			let width = Swift.max(fragment.bounds.width, 0.1)
			let height = Swift.max(fragment.bounds.height, 0)
			let isVerticalCandidate = splitVerticalFragments
				&& height >= width * verticalAspectRatioThreshold
				&& (typicalHeight == 0 || height >= typicalHeight * verticalHeightMultiplier)

			if isVerticalCandidate {
				verticalFragments.append(fragment)
			} else {
				horizontalFragments.append(fragment)
			}
		}

		var lines = [TextLine]()
		var unprocessedFragments = horizontalFragments.sorted { $0.bounds.minX < $1.bounds.minX }

		while !unprocessedFragments.isEmpty {
			let firstFragment = unprocessedFragments.removeFirst()
			var currentLineFragments = [firstFragment]

			// Check if other fragments overlap vertically with the current line
			let midY = firstFragment.bounds.midY
			unprocessedFragments = unprocessedFragments.filter { fragment in
				let overlaps = midY >= fragment.bounds.minY && midY <= fragment.bounds.maxY
				if overlaps {
					currentLineFragments.append(fragment)
				}
				return !overlaps
			}

			// Sort fragments within the line by X
			currentLineFragments.sort { $0.bounds.minX < $1.bounds.minX }

			// Add the assembled line
			lines.append(TextLine(fragments: currentLineFragments))
		}

		if splitVerticalFragments {
			lines.append(contentsOf: verticalFragments.map { TextLine(fragments: [$0]) })
		}

		// Sort lines by Y (top to bottom)
		lines.sort { $0.yPosition < $1.yPosition }

		return lines
	}
}

public extension Array where Element == TextLine {
	/// Converts an array of text lines into a single string, preserving vertical spacing and page breaks.
	func string() -> String {
		guard !isEmpty else { return "" }

		var result = ""
		var previousLine: TextLine?

		for line in self {
			if let previous = previousLine {
				if line.yPosition > previous.yPosition {
					// same page

					// Compute the vertical distance between the current line and the previous one
					let distance = abs(previous.yPosition - line.yPosition)

					let previousHeight = previous.fragments.map { $0.bounds.height }.max() ?? 0
					let height = line.fragments.map { $0.bounds.height }.max() ?? 0
					let averageHeight = Swift.max((previousHeight + height) / 2, 1)

					let emptyLines = Swift.max(1, Int(round(distance / averageHeight)))

					if emptyLines > 0 {
						// add emptyLines times \n
						result += String(repeating: "\n", count: emptyLines)
					}
				} else {
					// new page
					result += "\n---\n"
				}
			}

			// Append the combined text of the current line
			result += line.combinedText
			previousLine = line
		}

		return result
	}
}
