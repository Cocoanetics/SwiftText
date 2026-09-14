//  TableIntrinsicSizingTests.swift
//  SwiftTextRenderTests

import Testing
@testable import SwiftTextRender

extension RenderPDFTests {
	@Test("Break-word does not reduce table min-content width")
	func breakWordPreservesTableMinContentWidth() async throws {
		let html = """
		<table><tr><td>Dokumentnummer</td><td>Several ordinary words create a wide preferred column</td></tr></table>
		"""
		func firstCell(for wrappingRule: String, contentWidth: Double = 220) async throws -> BlockBox {
			let css = ["table { max-width: 100%; } td { padding: 0; \(wrappingRule) }"]
			let root = try await layoutTree(html, css: css, contentWidth: contentWidth)
			let cells = collectBlocks(in: root) { $0.element?.localName == "td" }
			return try #require(cells.first)
		}

		let normal = try await firstCell(for: "overflow-wrap: normal")
		let breakWord = try await firstCell(for: "overflow-wrap: break-word")
		let anywhere = try await firstCell(for: "overflow-wrap: anywhere")
		let breakAll = try await firstCell(for: "word-break: break-all")
		let constrainedBreakWord = try await firstCell(for: "overflow-wrap: break-word", contentWidth: 80)

		#expect(abs(breakWord.width - normal.width) < 0.01)
		#expect(anywhere.width < breakWord.width)
		#expect(abs(breakAll.width - anywhere.width) < 0.01)
		#expect(breakWord.lines.count == 1)
		#expect(anywhere.lines.count > 1)
		#expect(constrainedBreakWord.lines.count > 1)
		#expect(constrainedBreakWord.lines.flatMap(\.fragments).map(\.text).joined() == "Dokumentnummer")
	}
}
