//  TableContentWidthTests.swift
//  SwiftTextRenderTests

import SwiftTextHTML
import Testing
@testable import SwiftTextRender

extension RenderPDFTests {
	/// #197: the diary table of an appendix, eight columns on a portrait A4 page.
	@Test("A wide Markdown table sizes its columns by content and keeps empty rows open")
	func wideTableColumnsFollowContent() async throws {
		let headers = ["Datum", "Madopar genommen um", "Beweglichkeit vorm. / nachm. / abends (je 1 bis 5)",
			"Blutdruck liegend / stehend", "Schwindel beim Aufstehen (ja/nein)", "Schlaf (gut/mittel/schlecht)",
			"Training (was, wie lang)", "Bemerkungen"]
		let emptyRow = "|" + String(repeating: " |", count: headers.count) + "\n"
		let markdown = "| " + headers.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: headers.count)
			+ "\n" + emptyRow + emptyRow
		let css = [MarkdownToHTML.defaultStylesheet, "body { max-width: none; margin: 0; padding: 0; }"]
		// A4 portrait with 2 cm margins, in CSS pixels.
		let root = try await layoutTree(MarkdownToHTML.convert(markdown), css: css, contentWidth: 642)

		let headerCells = collectBlocks(in: root) { $0.element?.localName == "th" }
		try #require(headerCells.count == headers.count)
		for (cell, header) in zip(headerCells, headers) {
			// Rebuild the cell's text from its lines: a line may end at a space or
			// after a slash, never inside a word.
			let lines = cell.lines.map { line in
				var text = ""
				var previousEnd: Double?
				for fragment in line.fragments {
					if let previousEnd, fragment.x - previousEnd > 0.5 { text += " " }
					text += fragment.text
					previousEnd = fragment.x + fragment.width
				}
				return text
			}
			let rebuilt = lines.joined(separator: "\n")
				.replacingOccurrences(of: " /\n", with: " / ")
				.replacingOccurrences(of: "/\n", with: "/")
				.replacingOccurrences(of: "\n", with: " ")
			#expect(rebuilt == header, "header broken inside a word: \(lines)")
		}

		let widths = headerCells.map(\.width)
		#expect(widths[0] < widths[2], "the short Datum column is as wide as the long one: \(widths)")

		let emptyCells = collectBlocks(in: root) { $0.element?.localName == "td" }
		try #require(emptyCells.count == 2 * headers.count)
		for cell in emptyCells {
			let style = cell.style
			let padding = (style.padding.top.resolved(percentageBasis: 0) ?? 0)
				+ (style.padding.bottom.resolved(percentageBasis: 0) ?? 0)
			#expect(cell.height >= style.resolvedLineHeight() + padding, "empty cell is only \(cell.height) high")
		}
	}
}
