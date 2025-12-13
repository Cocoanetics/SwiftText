//
//  DocumentBlockTranscript.swift
//  SwiftTextPDF
//
//  Created by OpenAI Codex on 11.12.24.
//

import Foundation

public extension Collection where Element == DocumentBlock {
	/// Returns a human-readable transcript assembled from the collection of document blocks.
	func transcript() -> String {
		let fragments = self.map { $0.transcriptFragment() }.filter { !$0.isEmpty }
		return fragments.joined(separator: "\n\n")
	}
}

private extension DocumentBlock {
	func transcriptFragment() -> String {
		switch kind {
		case .paragraph(let paragraph):
			return normalizedLines(from: paragraph.lines, fallback: paragraph.text)
		case .list(let list):
			return format(list: list)
		case .table(let table):
			return format(table: table)
		case .image(let image):
			return format(image: image)
		}
	}
	
	func normalizedLines(from lines: [TextLine], fallback: String) -> String {
		let trimmedLines = lines
			.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		
		if trimmedLines.isEmpty {
			return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		
		return trimmedLines.joined(separator: "\n")
	}
	
	func format(list: DocumentBlock.List) -> String {
		list.items.enumerated().map { index, item in
			let marker = item.markerString.isEmpty ? list.marker.formatted(index: index) : item.markerString
			let content = normalizedLines(from: item.lines, fallback: item.text)
			return indenting(content, prefix: "\(marker) ")
		}.joined(separator: "\n")
	}
	
	func format(table: DocumentBlock.Table) -> String {
		table.rows.map { row in
			row.map { cell -> String in
				let text = normalizedLines(from: cell.lines, fallback: cell.text)
				return text.isEmpty ? " " : text
			}.joined(separator: " | ")
		}.joined(separator: "\n")
	}
	
	func format(image: DocumentBlock.Image) -> String {
		if let caption = image.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
		   !caption.isEmpty {
			return "[Image: \(caption)]"
		}
		
		return "[Image]"
	}
	
	func indenting(_ content: String, prefix: String) -> String {
		let lines = content.components(separatedBy: .newlines)
		guard let first = lines.first else {
			return prefix.trimmingCharacters(in: .whitespaces)
		}
		
		let remainder = lines.dropFirst()
		let indentation = String(repeating: " ", count: prefix.count)
		let tail = remainder.map { indentation + $0 }.joined(separator: "\n")
		
		if tail.isEmpty {
			return prefix + first
		}
		
		return prefix + first + "\n" + tail
	}
}

private extension DocumentBlock.List.Marker {
	func formatted(index: Int) -> String {
		switch self {
		case .bullet:
			return "•"
		case .hyphen:
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
}
