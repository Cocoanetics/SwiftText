import SwiftTextIWA
import Foundation

/// A read-only handle on an Apple Numbers (`.numbers`) spreadsheet, mirroring the shape
/// of `PagesFile`: construct it with a URL, then ask for the rendering you want. Output
/// is the spreadsheet's *current values* — the cached results Numbers froze into each
/// cell — with no formula recalculation.
public final class NumbersFile {
	public let url: URL
	public let document: NumbersDocument

	public init(url: URL) throws {
		self.url = url
		self.document = try NumbersParser().readDocument(from: url)
	}

	/// GitHub-flavored Markdown: one pipe table per spreadsheet table, each preceded by
	/// its sheet's name as a level-2 heading when the document names more than one sheet.
	public func markdown() -> String {
		var blocks = [String]()
		let labelSheets = document.sheets.count > 1
		for sheet in document.sheets {
			let tables = sheet.tables.compactMap { $0.trimmedToUsedRange() }
			guard !tables.isEmpty else { continue }
			if labelSheets, let name = sheet.name { blocks.append("## \(name)") }
			for table in tables { blocks.append(Self.markdownTable(table)) }
		}
		return blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n")
	}

	/// A standalone HTML fragment: one `<table>` per spreadsheet table, sheet names as
	/// `<h2>` when there is more than one sheet.
	public func html() -> String {
		var out = [String]()
		let labelSheets = document.sheets.count > 1
		for sheet in document.sheets {
			let tables = sheet.tables.compactMap { $0.trimmedToUsedRange() }
			guard !tables.isEmpty else { continue }
			if labelSheets, let name = sheet.name { out.append("<h2>\(Self.escapeHTML(name))</h2>") }
			for table in tables { out.append(Self.htmlTable(table)) }
		}
		return out.joined(separator: "\n")
	}

	/// The document as JSON — sheets of used-range tables — for programmatic and LLM-agent
	/// consumption. The shape is the `Codable` `NumbersDocument` with each table cropped to
	/// its used range.
	public func json() throws -> String {
		let trimmed = NumbersDocument(sheets: document.sheets.map { sheet in
			NumbersDocument.Sheet(name: sheet.name, tables: sheet.tables.compactMap { $0.trimmedToUsedRange() })
		})
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		return String(decoding: try encoder.encode(trimmed), as: UTF8.self)
	}

	/// Tab-separated values, one block per table (blank line between tables/sheets).
	public func plainText() -> String {
		var blocks = [String]()
		for sheet in document.sheets {
			for table in sheet.tables.compactMap({ $0.trimmedToUsedRange() }) {
				blocks.append(table.cells.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
			}
		}
		return blocks.joined(separator: "\n\n")
	}

	// MARK: - Markdown

	private static func markdownTable(_ table: TSTTable) -> String {
		let columns = table.columns
		guard columns > 0, !table.cells.isEmpty else { return "" }
		func row(_ values: [String]) -> String {
			let cells = (0..<columns).map { values.indices.contains($0) ? escapeMarkdown(values[$0]) : "" }
			return "| " + cells.joined(separator: " | ") + " |"
		}
		func separator() -> String {
			let marks = (0..<columns).map { column -> String in
				switch column < table.columnAlignments.count ? table.columnAlignments[column] : .left {
				case .left: return "---"
				case .center: return ":-:"
				case .right: return "--:"
				}
			}
			return "| " + marks.joined(separator: " | ") + " |"
		}
		var lines = [row(table.cells[0]), separator()]
		lines.append(contentsOf: table.cells.dropFirst().map(row))
		return lines.joined(separator: "\n")
	}

	private static func escapeMarkdown(_ value: String) -> String {
		value
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "|", with: "\\|")
			.replacingOccurrences(of: "\n", with: "<br>")
	}

	// MARK: - HTML

	private static func htmlTable(_ table: TSTTable) -> String {
		func cellTag(_ value: String, header: Bool, column: Int) -> String {
			let tag = header ? "th" : "td"
			let align = column < table.columnAlignments.count ? table.columnAlignments[column] : .left
			let style = align == .left ? "" : " style=\"text-align:\(align.rawValue)\""
			return "<\(tag)\(style)>\(escapeHTML(value))</\(tag)>"
		}
		func rowTag(_ values: [String], header: Bool) -> String {
			let cells = (0..<table.columns).map { cellTag(values.indices.contains($0) ? values[$0] : "", header: header, column: $0) }
			return "  <tr>" + cells.joined() + "</tr>"
		}
		var lines = ["<table>"]
		if let head = table.cells.first { lines.append(rowTag(head, header: true)) }
		lines.append(contentsOf: table.cells.dropFirst().map { rowTag($0, header: false) })
		lines.append("</table>")
		return lines.joined(separator: "\n")
	}

	private static func escapeHTML(_ value: String) -> String {
		value
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
	}
}
