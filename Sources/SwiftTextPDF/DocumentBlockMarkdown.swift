//
//  DocumentBlockMarkdown.swift
//  SwiftTextPDF
//
//  Created by OpenAI Codex on 12.12.24.
//

import Foundation

public struct DocumentBlockMarkdownRenderer {
	public static func markdown(from blocks: [DocumentBlock], imageResolver: ((DocumentBlock) -> String?)? = nil) -> String {
		let fragments = blocks.map { block -> String in
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
}
