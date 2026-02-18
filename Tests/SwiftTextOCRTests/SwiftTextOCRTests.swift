//
//  SwiftTextOCRTests.swift
//  SwiftTextOCR
//
//  Created by Oliver Drobnik on 09.12.24.
//

import Foundation
import Testing

@testable import SwiftTextOCR

struct SwiftTextOCRTests {
	
	@Test func testDocumentTranscriptRendering() {
		let paragraphBlock = DocumentBlock(
			bounds: CGRect(x: 0, y: 0, width: 200, height: 32),
			kind: .paragraph(
				.init(
					text: "First paragraph.",
					lines: [
						.init(text: "First paragraph.", bounds: CGRect(x: 0, y: 0, width: 200, height: 16))
					]
				)
			)
		)
		let listBlock = DocumentBlock(
			bounds: CGRect(x: 0, y: 40, width: 200, height: 48),
			kind: .list(
				.init(
					marker: .decimal,
					items: [
						.init(
							text: "First item",
							markerString: "",
							bounds: CGRect(x: 0, y: 40, width: 200, height: 16),
							lines: [.init(text: "First item", bounds: CGRect(x: 0, y: 40, width: 200, height: 16))]
						),
						.init(
							text: "Second item",
							markerString: "",
							bounds: CGRect(x: 0, y: 56, width: 200, height: 16),
							lines: [.init(text: "Second item", bounds: CGRect(x: 0, y: 56, width: 200, height: 16))]
						)
					]
				)
			)
		)
		
		let tableBlock = DocumentBlock(
			bounds: CGRect(x: 0, y: 96, width: 200, height: 48),
			kind: .table(
				.init(
					rows: [
						[
							.init(rowRange: 0...0, columnRange: 0...0, text: "A1", bounds: CGRect(x: 0, y: 96, width: 100, height: 24), lines: [.init(text: "A1", bounds: CGRect(x: 0, y: 96, width: 100, height: 24))]),
							.init(rowRange: 0...0, columnRange: 1...1, text: "B1", bounds: CGRect(x: 100, y: 96, width: 100, height: 24), lines: [.init(text: "B1", bounds: CGRect(x: 100, y: 96, width: 100, height: 24))])
						],
						[
							.init(rowRange: 1...1, columnRange: 0...0, text: "A2", bounds: CGRect(x: 0, y: 120, width: 100, height: 24), lines: [.init(text: "A2", bounds: CGRect(x: 0, y: 120, width: 100, height: 24))]),
							.init(rowRange: 1...1, columnRange: 1...1, text: "B2", bounds: CGRect(x: 100, y: 120, width: 100, height: 24), lines: [.init(text: "B2", bounds: CGRect(x: 100, y: 120, width: 100, height: 24))])
						]
					]
				)
			)
		)
		
		let imageBlock = DocumentBlock(
			bounds: CGRect(x: 0, y: 160, width: 100, height: 100),
			kind: .image(.init(caption: "Sample image"))
		)
		
		let blocks = [paragraphBlock, listBlock, tableBlock, imageBlock]
		let transcript = blocks.transcript()
		
		let expected = """
		First paragraph.
		
		1. First item
		2. Second item
		
		A1 | B1
		A2 | B2
		
		[Image: Sample image]
		"""
		
		#expect(transcript == expected)
	}
	
	@Test func testMarkdownRendering() {
		let paragraphBlock = DocumentBlock(
			bounds: CGRect(x: 0, y: 0, width: 200, height: 32),
			kind: .paragraph(.init(text: "Hello paragraph.", lines: [.init(text: "Hello paragraph.", bounds: .zero)]))
		)
		
		let listBlock = DocumentBlock(
			bounds: CGRect(x: 0, y: 40, width: 200, height: 48),
			kind: .list(
				.init(
					marker: .decimal,
					items: [
						.init(text: "First item", markerString: "", bounds: .zero, lines: [.init(text: "First item", bounds: .zero)]),
						.init(text: "Second item", markerString: "", bounds: .zero, lines: [.init(text: "Second item", bounds: .zero)])
					]
				)
			)
		)
		
		let tableBlock = DocumentBlock(
			bounds: CGRect(x: 0, y: 96, width: 200, height: 48),
			kind: .table(
				.init(
					rows: [
						[
							.init(rowRange: 0...0, columnRange: 0...0, text: "A1", bounds: .zero, lines: [.init(text: "A1", bounds: .zero)]),
							.init(rowRange: 0...0, columnRange: 1...1, text: "B1", bounds: .zero, lines: [.init(text: "B1", bounds: .zero)])
						],
						[
							.init(rowRange: 1...1, columnRange: 0...0, text: "A2", bounds: .zero, lines: [.init(text: "A2", bounds: .zero)]),
							.init(rowRange: 1...1, columnRange: 1...1, text: "B2", bounds: .zero, lines: [.init(text: "B2", bounds: .zero)])
						]
					]
				)
			)
		)
		
		let imageBlock = DocumentBlock(
			bounds: CGRect(x: 0, y: 160, width: 100, height: 100),
			kind: .image(.init(caption: "Sample image"))
		)
		
		let markdown = DocumentBlockMarkdownRenderer.markdown(from: [paragraphBlock, listBlock, tableBlock, imageBlock]) { block in
			if case .image = block.kind {
				return "image-1.png"
			}
			return nil
		}
		
		let expected = """
		Hello paragraph.
		
		1. First item
		2. Second item
		
		| A1 | B1 |
		| --- | --- |
		| A2 | B2 |
		
		![Image](image-1.png)
		"""
		
		#expect(markdown == expected)
	}
	
	@Test func testTextLineAssembly() async throws {
		let fragment1 = TextFragment(bounds: CGRect(x: 0, y: 0, width: 50, height: 12), string: "Hello")
		let fragment2 = TextFragment(bounds: CGRect(x: 60, y: 0, width: 50, height: 12), string: "World")
		let fragment3 = TextFragment(bounds: CGRect(x: 0, y: 20, width: 100, height: 12), string: "Second line")
		
		let fragments = [fragment1, fragment2, fragment3]
		let lines = fragments.assembledLines()
		
		#expect(lines.count == 2)
		#expect(lines[0].combinedText == "Hello\tWorld")
		#expect(lines[1].combinedText == "Second line")
	}
	
	@Test func testVerticalFragmentsSplitIntoSeparateLine() async throws {
		let vertical = TextFragment(bounds: CGRect(x: 0, y: 0, width: 6, height: 40), string: "vertical")
		let fragment1 = TextFragment(bounds: CGRect(x: 10, y: 60, width: 40, height: 10), string: "Hello")
		let fragment2 = TextFragment(bounds: CGRect(x: 60, y: 60, width: 40, height: 10), string: "World")
		
		let lines = [vertical, fragment1, fragment2].assembledLines(splitVerticalFragments: true)
		
		#expect(lines.count == 2)
		let verticalLine = lines.first { $0.fragments.count == 1 && $0.fragments.first?.string == "vertical" }
		let horizontalLine = lines.first { $0.fragments.count == 2 }
		
		#expect(verticalLine != nil, "Expected the vertical fragment to form its own line")
		#expect(horizontalLine?.combinedText == "Hello\tWorld")
	}
	
	@Test func testTextLineString() async throws {
		let line1 = TextLine(fragments: [TextFragment(bounds: CGRect(x: 0, y: 0, width: 100, height: 12), string: "First line")])
		let line2 = TextLine(fragments: [TextFragment(bounds: CGRect(x: 0, y: 14, width: 100, height: 12), string: "Second line")])
		
		let lines = [line1, line2]
		let result = lines.string()
		
		#expect(result.contains("First line"))
		#expect(result.contains("Second line"))
	}
}
