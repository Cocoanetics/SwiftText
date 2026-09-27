//
//  DocumentBlock.swift
//  SwiftTextPDF
//
//  Created by OpenAI Codex on 11.12.24.
//

import CoreGraphics
import Foundation

/// Represents a logical block of structured content extracted from a PDF page.
public struct DocumentBlock: Equatable, Sendable {
	public let bounds: CGRect
	public let kind: Kind

	/// Convenience access to the block's top-left coordinate (origin at the page's top edge).
	public var topLeft: CGPoint {
		CGPoint(x: bounds.minX, y: bounds.minY)
	}

	public enum Kind: Equatable, Sendable {
		case paragraph(Paragraph)
		case list(List)
		case table(Table)
		case image(Image)
	}
}

extension DocumentBlock: Comparable {
	public static func < (lhs: DocumentBlock, rhs: DocumentBlock) -> Bool {
		let verticalDelta = lhs.bounds.minY - rhs.bounds.minY

		if abs(verticalDelta) > 4 {
			return verticalDelta < 0
		}

		return lhs.bounds.minX < rhs.bounds.minX
	}
}

public extension DocumentBlock {
	struct TextLine: Equatable, Sendable {
		public let text: String
		public let bounds: CGRect
		/// How the parts of ``text`` are set, covering it exactly. Empty when the
		/// source cannot report style, as OCR cannot.
		public let runs: [StyleRun]

		public init(text: String, bounds: CGRect, runs: [StyleRun] = []) {
			self.text = text
			self.bounds = bounds
			self.runs = runs
		}

		/// A line whose text is exactly what `runs` cover.
		public init(runs: [StyleRun], bounds: CGRect) {
			self.init(text: runs.text, bounds: bounds, runs: runs)
		}
	}

	struct Paragraph: Equatable, Sendable {
		public let text: String
		public let lines: [TextLine]
		/// 1...6 when the page sets this paragraph as a heading, else nil.
		/// Assigned when the blocks are read, from how the text is set relative
		/// to the rest of the document.
		public let headingLevel: Int?

		public init(text: String, lines: [TextLine], headingLevel: Int? = nil) {
			self.text = text
			self.lines = lines
			self.headingLevel = headingLevel
		}
	}

	struct List: Equatable, Sendable {
		public let marker: Marker
		public let items: [Item]

		public enum Marker: Equatable, Sendable {
			case bullet
			case hyphen
			case lowercaseLatin
			case uppercaseLatin
			case decimal
			case decorativeDecimal
			case compositeDecimal
			case custom(String)
		}

		public struct Item: Equatable, Sendable {
			public let text: String
			public let markerString: String
			public let bounds: CGRect
			public let lines: [TextLine]
		}
	}

	struct Table: Equatable, Sendable {
		public let rows: [[Cell]]

		public struct Cell: Equatable, Sendable {
			public let rowRange: ClosedRange<Int>
			public let columnRange: ClosedRange<Int>
			public let text: String
			public let bounds: CGRect
			public let lines: [TextLine]
		}
	}

	struct Image: Equatable, Sendable {
		public let caption: String?
	}
}
