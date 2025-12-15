//
//  DocumentBlockMarkdown.swift
//  SwiftTextPDF
//
//  Created by OpenAI Codex on 12.12.24.
//

import Foundation

public struct DocumentBlockMarkdownRenderer {
	public static func markdown(
		from blocks: [DocumentBlock],
		textLines: [DocumentBlock.TextLine]? = nil,
		imageResolver: ((DocumentBlock) -> String?)? = nil
	) -> String {
		let pageBounds = boundsForPage(from: blocks, textLines: textLines)
		let orderedBlocks: [DocumentBlock]
		if let lines = textLines, !lines.isEmpty {
			let indexed = blocks.enumerated()
			orderedBlocks = indexed.sorted { lhs, rhs in
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
		} else {
			orderedBlocks = blocks.sorted { lhs, rhs in
				isInReadingOrder(lhs.bounds, rhs.bounds, pageBounds: pageBounds)
			}
		}
		
		let fragments = orderedBlocks.map { block -> String in
			switch block.kind {
			case .paragraph(let paragraph):
				return format(paragraph)
			case .list(let list):
				return format(list)
			case .table(let table):
				return format(table)
			case .image:
				let resolved = imageResolver?(block)
				return formatImage(path: resolved)
			}
		}.filter { !$0.isEmpty }
		
		return fragments.joined(separator: "\n\n")
	}
	
	private static func format(_ paragraph: DocumentBlock.Paragraph) -> String {
		let lines = paragraph.lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
		if lines.isEmpty {
			return paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return lines.joined(separator: "\n")
	}
	
	private static func format(_ list: DocumentBlock.List) -> String {
		return list.items.enumerated().map { index, item in
			let marker = resolvedMarker(for: list.marker, index: index, fallback: item.markerString)
			return formatListLine(prefix: marker, text: item.text)
		}.joined(separator: "\n")
	}
	
	private static func format(_ table: DocumentBlock.Table) -> String {
		let rows = table.rows.map { row in
			"| " + row.map { cell in
				let text = cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
				return text.isEmpty ? " " : text.replacingOccurrences(of: "|", with: "\\|")
			}.joined(separator: " | ") + " |"
		}
		return rows.joined(separator: "\n")
	}
	
	private static func formatImage(path: String?) -> String {
		if let path, !path.isEmpty {
			return "![Image](\(path))"
		} else {
			return "![Image]()"
		}
	}
	
	private static func formatListLine(prefix: String, text: String) -> String {
		let lines = text.components(separatedBy: .newlines)
		guard let first = lines.first else { return prefix }
		let indent = String(repeating: " ", count: prefix.count + 1)
		let tail = lines.dropFirst().map { indent + $0 }.joined(separator: "\n")
		if tail.isEmpty {
			return "\(prefix) \(first)"
		} else {
			return "\(prefix) \(first)\n\(tail)"
		}
	}
	
	private static func resolvedMarker(for marker: DocumentBlock.List.Marker, index: Int, fallback: String) -> String {
		if !fallback.isEmpty { return fallback }
		
		switch marker {
		case .bullet, .hyphen:
			return "-"
		case .lowercaseLatin:
			let scalar = UnicodeScalar(97 + (index % 26))!
			return "\(Character(scalar))."
		case .uppercaseLatin:
			let scalar = UnicodeScalar(65 + (index % 26))!
			return "\(Character(scalar))."
		case .decimal, .decorativeDecimal, .compositeDecimal:
			return "\(index + 1)."
		case .custom(let string):
			return string.isEmpty ? "-" : string
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
