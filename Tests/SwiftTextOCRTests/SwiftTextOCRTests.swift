//
//  SwiftTextOCRTests.swift
//  SwiftTextOCR
//
//  Created by Oliver Drobnik on 09.12.24.
//

import Foundation
import ImageIO
import PDFKit
import Testing
#if canImport(Vision)
import Vision
#endif
import UniformTypeIdentifiers
#if canImport(Vision)
import Vision
#endif

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
		
		print("Transcript sample:\n\(transcript)")
		
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
	
	@Test func testSemanticOverlayExport() async throws {
		#if canImport(Vision)
		guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else { return }
		
		let pdfPath = ("~/Desktop/Inuspherese/Aufklärungsbogen DE.pdf" as NSString).expandingTildeInPath
		let pdfURL = URL(fileURLWithPath: pdfPath)
		let fileExists = FileManager.default.fileExists(atPath: pdfPath)
		#expect(fileExists, "Expected PDF fixture at \(pdfPath)")
		guard fileExists, let document = PDFDocument(url: pdfURL) else { return }
		
		let exportDir = URL(fileURLWithPath: ("~/Desktop/SwiftTextExports" as NSString).expandingTildeInPath, isDirectory: true)
		try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
		let overlayDPI: CGFloat = 300
		
		for pageIndex in 0..<document.pageCount {
			guard let page = document.page(at: pageIndex) else { continue }
			let (blocks, _) = try await page.documentBlocksWithImages(dpi: overlayDPI)
			let textLines = page.textLines()
			let rectangles = try page.detectedRectangles(dpi: overlayDPI)
			let imageURL = exportDir.appendingPathComponent("page-\(pageIndex + 1)-overlay.png")
			try renderOverlay(for: page, blocks: blocks, lines: textLines, rectangles: rectangles, dpi: overlayDPI, to: imageURL)
			#expect(FileManager.default.fileExists(atPath: imageURL.path), "Failed to export overlay for page \(pageIndex + 1)")
		}
		#else
		#expect(true, "Vision not available; skipping semantic overlay export test")
		#endif
	}
	
	@Test func testPNGTextExtraction() async throws {
		#if canImport(Vision)
		guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else {
			return
		}
		
		let pngPath = ("~/Desktop/mastercard_test.png" as NSString).expandingTildeInPath
		let pngURL = URL(fileURLWithPath: pngPath)
		let fileExists = FileManager.default.fileExists(atPath: pngPath)
		#expect(fileExists, "Expected PNG fixture at \(pngPath)")
		guard fileExists else { return }
		
		guard
			let source = CGImageSourceCreateWithURL(pngURL as CFURL, nil),
			let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
		else {
			#expect(false, "Unable to decode PNG at \(pngPath)")
			return
		}
		
		let recognizeRequest = RecognizeDocumentsRequest()
		let observations = try await recognizeRequest.perform(on: cgImage, orientation: nil)
		#expect(!observations.isEmpty, "RecognizeDocumentsRequest returned no observations for \(pngPath)")
		guard let document = observations.first?.document else {
			#expect(false, "No document container returned for \(pngPath)")
			return
		}
		
		print("PNG document transcript:\n\(document.text.transcript)")
		
		for paragraph in document.paragraphs {
			let text = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !text.isEmpty else { continue }
			print("PNG paragraph: \(text)")
			
			for line in paragraph.lines {
				let bestCandidate = line.topCandidates(1).first?.string ?? ""
				let trimmed = bestCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
				guard !trimmed.isEmpty else { continue }
				print("  line candidate: \(trimmed)")
			}
		}
		
		let pageSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
		let extractor = DocumentBlockExtractor(image: cgImage, pageSize: pageSize)
		let blocks = try extractor.extractBlocks(from: document)
		#expect(!blocks.isEmpty, "Expected document blocks for \(pngPath)")
		
		let transcript = blocks.transcript()
		print("PNG transcript:\n\(transcript)")
		
		let startSnippet = "Aufgrund einer medizinischen Sondersituation (z.B. Versagen einer vorangegangenen Therapie,"
		let gibberishSnippet = "solsch therapiechste noriensel-Sphereseais mein inankndlins erstin arzthanalung."
		
		#expect(transcript.contains(startSnippet), "Transcript missing recognized beginning of problematic paragraph from PNG")
		#expect(transcript.contains(gibberishSnippet), "Transcript missing Vision's garbled middle section for the problematic paragraph")
		#else
		#expect(true, "Vision not available; skipping PNG extraction test")
		#endif
	}
	
	@Test func testPNGSegmentationMatchesOCRLines() async throws {
		#if canImport(Vision)
		guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else {
			return
		}
		
		let pngPath = ("~/Desktop/mastercard_test.png" as NSString).expandingTildeInPath
		let pngURL = URL(fileURLWithPath: pngPath)
		let fileExists = FileManager.default.fileExists(atPath: pngPath)
		#expect(fileExists, "Expected PNG fixture at \(pngPath)")
		guard fileExists else { return }
		
		guard
			let source = CGImageSourceCreateWithURL(pngURL as CFURL, nil),
			let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
		else {
			#expect(false, "Unable to decode PNG at \(pngPath)")
			return
		}
		
		let pageSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
		
		let ocrLines = try cgImage.performOCR(imageSize: pageSize) ?? []
		let ocrStrings = ocrLines
			.map { $0.combinedText.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		
		let ocrOutput = ocrStrings.joined(separator: "\n")
		print("Raw OCR lines:\n\(ocrOutput)")
		
		#expect(!ocrStrings.isEmpty, "OCR returned no lines for \(pngPath)")
		
		let recognizeRequest = RecognizeDocumentsRequest()
		let observations = try await recognizeRequest.perform(on: cgImage, orientation: nil)
		#expect(!observations.isEmpty, "RecognizeDocumentsRequest returned no observations for \(pngPath)")
		guard let document = observations.first?.document else {
			#expect(false, "No document container returned for \(pngPath)")
			return
		}

		let extractor = DocumentBlockExtractor(image: cgImage, pageSize: pageSize)
		let blocks = try extractor.extractBlocks(from: document)
		let transcript = blocks.transcript()
		
		print("Segmented transcript:\n\(transcript)")
		for block in blocks {
			switch block.kind {
				case .paragraph(let paragraph):
					print("Paragraph block: \(paragraph.text)")
					for line in paragraph.lines {
						print("  textLine: \(line.text)")
					}
			case .list(let list):
				let items = list.items.map(\.text).joined(separator: " | ")
				print("List block: \(items)")
			case .table(let table):
				let cells = table.rows.flatMap { $0 }.map(\.text).joined(separator: " | ")
				print("Table block: \(cells)")
			case .image:
				print("Image block")
			}
		}
		
		let missingLines = ocrStrings.filter { !transcript.contains($0) }
		if !missingLines.isEmpty {
			let joined = missingLines.joined(separator: "\n")
			print("Missing OCR lines from segmented transcript:\n\(joined)")
		}
		
		#expect(missingLines.isEmpty, "Segmented transcript should include all OCR-recognized lines")
		#else
		#expect(true, "Vision not available; skipping PNG OCR comparison test")
		#endif
	}

	@Test func testParagraphMergingForTestPNG() async throws {
		#if canImport(Vision)
		guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else {
			return
		}

		let pngPath = ("~/Desktop/mastercard_test.png" as NSString).expandingTildeInPath
		let pngURL = URL(fileURLWithPath: pngPath)
		let fileExists = FileManager.default.fileExists(atPath: pngPath)
		#expect(fileExists, "Expected PNG fixture at \(pngPath)")
		guard fileExists else { return }

		guard
			let source = CGImageSourceCreateWithURL(pngURL as CFURL, nil),
			let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
		else {
			#expect(false, "Unable to decode PNG at \(pngPath)")
			return
		}

		let pageSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
		let result = try await documentBlocks(from: cgImage)
		let processed = postProcessBlocks(result.blocks, pageSize: pageSize)

		let paragraphs = processed.compactMap { block -> String? in
			if case .paragraph(let paragraph) = block.kind {
				return paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
			}
			return nil
		}



		let hasAddress = paragraphs.contains { text in
			text.contains("CC Inuspherese GmbH") && text.contains("Tel. Nr. 0677 64564459")
		}
		let hasGreeting = paragraphs.contains { text in
			text == "Sehr geehrte/r Patient/in, (m/w/d)"
		}
		let hasMedicalParagraph = paragraphs.contains { text in
			text.contains("Aufgrund einer medizinischen Sondersituation") && text.contains("Nebenwirkungen der Therapie 24 Stunden vor der Behandlung vorgeschrieben.")
		}
		let hasHeading = paragraphs.contains { text in
			text.contains("Verfahrensweise: Die INUSpherese®") && text.contains("Die %uale Entlastung ist individuell.")
		}

		#expect(hasAddress, "Expected merged address paragraph")
		#expect(hasGreeting, "Expected greeting line to stay separate")
		#expect(hasMedicalParagraph, "Expected medical paragraph to remain grouped")
		#expect(hasHeading, "Expected merged heading paragraph")
		#else
		#expect(true, "Vision not available; skipping paragraph merge test")
		#endif
	}
	
	@Test func testSemanticGroupingForTestPNG() async throws {
		#if canImport(Vision)
		guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else {
			return
		}
		
		let pngPath = ("~/Desktop/mastercard_test.png" as NSString).expandingTildeInPath
		let pngURL = URL(fileURLWithPath: pngPath)
		let fileExists = FileManager.default.fileExists(atPath: pngPath)
		#expect(fileExists, "Expected PNG fixture at \(pngPath)")
		guard fileExists else { return }
		
		guard
			let source = CGImageSourceCreateWithURL(pngURL as CFURL, nil),
			let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
		else {
			#expect(false, "Unable to decode PNG at \(pngPath)")
			return
		}
		
		let pageSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
		let textLines = cgImage.textLines(imageSize: pageSize)
		let semantics = try await documentSemantics(from: cgImage)
		let groupedBlocks = TextLineSemanticComposer.composeBlocks(
			from: textLines,
			semantics: semantics,
			layoutSize: pageSize
		)
		
		let semanticTables = semantics.blocks.compactMap { block -> DocumentBlock.Table? in
			if case .table(let table) = block.block.kind {
				return table
			}
			return nil
		}

		let desktopURL = URL(fileURLWithPath: ("~/Desktop" as NSString).expandingTildeInPath, isDirectory: true)
		let pageBounds = CGRect(origin: .zero, size: pageSize)
		for (tableIndex, table) in semanticTables.enumerated() {
			guard let headerRow = table.rows.first else { continue }
			for (cellIndex, cell) in headerRow.enumerated() {
				let rect = clampedRect(cell.bounds.insetBy(dx: -6, dy: -2).integral, to: pageBounds)
				guard rect.width > 1, rect.height > 1 else { continue }
				guard let cropped = cgImage.cropping(to: rect) else { continue }
				let filename = "header-table\(tableIndex)-col\(cellIndex).png"
				let url = desktopURL.appendingPathComponent(filename)
				try writePNG(cropped, to: url)
			}
		}
		
		let tableStructure = semanticTables.map { table -> String in
			let rows = table.rows.enumerated().map { rowIndex, row -> String in
				let values = row.map { normalizedCellText($0.text) }
				let rowValues = values.map { $0.isEmpty ? "\"\"" : $0 }
				return "    row\(rowIndex) { \(rowValues.joined(separator: ", ")) }"
			}
			return "{\n\(rows.joined(separator: "\n"))\n}"
		}.joined(separator: "\n")
		print("Semantic table structure:\n\(tableStructure)")
		
		let keywordLines = textLines.compactMap { line -> String? in
			let text = line.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !text.isEmpty else { return nil }
			if text.localizedCaseInsensitiveContains("karte") || text.localizedCaseInsensitiveContains("umsatz") {
				return text
			}
			return nil
		}
		if !keywordLines.isEmpty {
			print("Keyword OCR lines:\n\(keywordLines.joined(separator: "\n"))")
		}
		
		if let tableBlock = semantics.blocks.first(where: { block in
			if case .table = block.block.kind { return true }
			return false
		}), !tableBlock.tableRows.isEmpty, let firstRow = tableBlock.tableRows.first {
			let rowBounds = firstRow.map { $0.normalizedBounds }
				.reduce(NormalizedRect.zero) { partial, rect in
					partial == .zero ? rect : partial.union(rect)
				}
				.scaled(to: pageSize)
			let overlapped = textLines.compactMap { line -> String? in
				let bounds = line.fragments.reduce(line.fragments.first?.bounds ?? .zero) { $0.union($1.bounds) }
				guard bounds.intersects(rowBounds) else { return nil }
				let text = line.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
				return text.isEmpty ? nil : text
			}
			if !overlapped.isEmpty {
				print("Row0 overlapped OCR lines:\n\(overlapped.joined(separator: "\n"))")
			}
		}
		
		let sourceLines = textLines
			.map { $0.combinedText.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		let assignedLines = groupedBlocks.flatMap { block -> [String] in
			switch block.kind {
			case .paragraph(let paragraph):
				return paragraph.lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
			case .list(let list):
				return list.items.flatMap { $0.lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) } }
			case .table(let table):
				return table.rows.flatMap { row in
					row.flatMap { cell in
						cell.lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
					}
				}
			case .image:
				return []
			}
		}.filter { !$0.isEmpty }
		
		#expect(sourceLines.count == assignedLines.count, "All text lines should be assigned to semantic blocks")
		let sourceSorted = sourceLines.sorted()
		let assignedSorted = assignedLines.sorted()
		#expect(sourceSorted == assignedSorted, "Expected semantic grouping to reuse every OCR text line")
		#else
		#expect(true, "Vision not available; skipping semantic grouping test")
		#endif
	}
	
	@Test func testMarkdownTableUsesSemanticCellsForMastercardPDF() async throws {
		#if canImport(Vision)
		guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else {
			return
		}
		
		let pdfPath = ("~/Downloads/MASTERCARD_2025_11_REF_NR_95382227957-overlay.pdf" as NSString).expandingTildeInPath
		let fileExists = FileManager.default.fileExists(atPath: pdfPath)
		#expect(fileExists, "Expected PDF fixture at \(pdfPath)")
		guard fileExists else { return }
		
		let pdfURL = URL(fileURLWithPath: pdfPath)
		guard let document = PDFDocument(url: pdfURL) else {
			#expect(Bool(false), "Unable to load PDF at \(pdfPath)")
			return
		}
		
		#expect(document.pageCount > 1, "Expected at least 2 pages in \(pdfPath)")
		guard let page = document.page(at: 1) else {
			#expect(Bool(false), "Unable to load page 2 from \(pdfPath)")
			return
		}
		
		let semantics = try await page.documentSemantics(dpi: 300, applyPostProcessing: false)
		let layoutSize = page.bounds(for: .mediaBox).size
		let textLines = page.textLines()
		let groupedBlocks = TextLineSemanticComposer.composeBlocks(
			from: textLines,
			semantics: semantics,
			layoutSize: layoutSize
		)
		
		let semanticTables = semantics.blocks.compactMap { block -> DocumentBlock.Table? in
			if case .table(let table) = block.block.kind {
				return table
			}
			return nil
		}
		let groupedTables = groupedBlocks.compactMap { block -> DocumentBlock.Table? in
			if case .table(let table) = block.kind {
				return table
			}
			return nil
		}
		
		guard !semanticTables.isEmpty, !groupedTables.isEmpty else {
			#expect(Bool(true), "No tables detected in the fixture; skipping markdown table comparison.")
			return
		}
		guard let semanticTable = semanticTables.max(by: { tableCellCount($0) < tableCellCount($1) }),
			  let groupedTable = groupedTables.max(by: { tableCellCount($0) < tableCellCount($1) })
		else {
			#expect(Bool(false), "Unable to resolve a table for comparison")
			return
		}
		
		guard semanticTable.rows.count == groupedTable.rows.count else {
			#expect(Bool(false), "Expected grouped table row count to match semantics")
			return
		}
		
		guard let rowIndex = semanticTable.rows.indices.max(by: { lhs, rhs in
			nonEmptyCellCount(in: semanticTable.rows[lhs]) < nonEmptyCellCount(in: semanticTable.rows[rhs])
		}) else {
			#expect(Bool(false), "Expected at least one table row")
			return
		}
		
		let expectedRow = semanticTable.rows[rowIndex].map { normalizedCellText($0.text) }
		let actualRow = groupedTable.rows[rowIndex].map { normalizedCellText($0.text) }
		
		let expectedNonEmpty = expectedRow.filter { !$0.isEmpty }
		#expect(expectedNonEmpty.count > 1, "Expected a semantic row with multiple populated columns")
		#expect(expectedRow == actualRow, "Expected grouped table cells to preserve semantic cell text by column")
		#else
		#expect(true, "Vision not available; skipping markdown table test")
		#endif
	}
	
	@Test func testTextLineAssembly() async throws {
		// Test that fragments are correctly assembled into lines
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
		// Test conversion of TextLines to string
		let line1 = TextLine(fragments: [TextFragment(bounds: CGRect(x: 0, y: 0, width: 100, height: 12), string: "First line")])
		let line2 = TextLine(fragments: [TextFragment(bounds: CGRect(x: 0, y: 14, width: 100, height: 12), string: "Second line")])
		
		let lines = [line1, line2]
		let result = lines.string()
		
		#expect(result.contains("First line"))
		#expect(result.contains("Second line"))
	}
	
	@Test func testDocumentBlocksExtraction() async throws {
			let directoryPath = ("~/Desktop/Inuspherese" as NSString).expandingTildeInPath
			let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
			
			let pdfURLs = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
				.filter { $0.pathExtension.lowercased() == "pdf" }
			
			#expect(!pdfURLs.isEmpty, "No PDF fixtures found in \(directoryPath)")
			
			var hasList = false
			var hasTable = false
			var hasImage = false
			
			for url in pdfURLs {
				let document = PDFDocument(url: url)
				#expect(document != nil, "Unable to load \(url.lastPathComponent)")
				
				for pageIndex in 0..<(document?.pageCount ?? 0) {
					guard let page = document?.page(at: pageIndex) else {
						continue
					}
					
					let blocks = try await page.documentBlocks()
					#expect(!blocks.isEmpty, "No blocks extracted for \(url.lastPathComponent) page \(pageIndex + 1)")
					
					let transcript = blocks.transcript()
					print("Transcript for \(url.lastPathComponent) page \(pageIndex + 1):\n\(transcript)\n---")
					
					#expect(blocks.contains { block in
						if case .paragraph = block.kind { return true }
						return false
					}, "Expected at least one paragraph block for \(url.lastPathComponent) page \(pageIndex + 1)")
					
					if blocks.contains(where: { block in
						if case .list = block.kind { return true }
						return false
					}) {
						hasList = true
					}
					
					if blocks.contains(where: { block in
						if case .table = block.kind { return true }
						return false
					}) {
						hasTable = true
					}
					
					if blocks.contains(where: { block in
						if case .image = block.kind { return true }
						return false
					}) {
						hasImage = true
					}
				}
			}
			
			#expect(hasList, "Expected at least one list within the provided fixtures")
			#expect(hasTable, "Expected at least one table within the provided fixtures")
			#expect(hasImage, "Expected to detect at least one image block within the provided fixtures")
		}
	
	@Test func testMasterCardSelectionMatchesOCR() async throws {
		#if canImport(Vision)
		guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else { return }
		
		let pdfPath = ("~/Downloads/MASTERCARD.pdf" as NSString).expandingTildeInPath
		let fileExists = FileManager.default.fileExists(atPath: pdfPath)
		#expect(fileExists, "The Mastercard fixture must exist at \(pdfPath)")
		guard fileExists, let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else { return }
		guard let page = document.page(at: 1) else {
			Issue.record("Unable to access the second page of the Mastercard PDF")
			return
		}
		
		guard let selectionLines = page.textLinesFromSelections(), !selectionLines.isEmpty else {
			Issue.record("Expected selectable text fragments for Mastercard page 2")
			return
		}
		
		guard let ocrLines = try page.performOCR(), !ocrLines.isEmpty else {
			Issue.record("Expected OCR text fragments for Mastercard page 2")
			return
		}
		
		struct Probe {
			let snippet: String
			let label: String
			let selectionSpan: Int
			let similarityThreshold: Double
		}
		if let selectionTransaction = selectionLines.first(where: { $0.combinedText.contains("CRV*BILLA DANKT 000344") }),
		   let ocrTransaction = ocrLines.first(where: { $0.combinedText.contains("CRV*BILLA DANKT 000344") })
		{
			print("Selection fragments for CRV row:")
			for fragment in selectionTransaction.fragments {
				print("  \"\(fragment.string)\" bounds: \(fragment.bounds)")
			}
			
			print("OCR fragments for CRV row:")
			for fragment in ocrTransaction.fragments {
				print("  \"\(fragment.string)\" bounds: \(fragment.bounds)")
			}
			
			logCharacterBounds(for: selectionTransaction.combinedText, in: page, label: "Selection line")
			logCharacterBounds(for: ocrTransaction.combinedText, in: page, label: "OCR line")
		}
		
		let probes: [Probe] = [
			.init(snippet: "Kontonummer", label: "account header", selectionSpan: 1, similarityThreshold: 0.75),
			.init(snippet: "Der offene Saldo", label: "debit notice", selectionSpan: 1, similarityThreshold: 0.9),
			.init(snippet: "Karte Umsatz Buchung", label: "table header", selectionSpan: 2, similarityThreshold: 0.45),
			.init(snippet: "CRV*BILLA DANKT 000344", label: "transaction row", selectionSpan: 1, similarityThreshold: 0.4)
		]
		
		for probe in probes {
			guard let ocrLine = ocrLines.first(where: { $0.combinedText.contains(probe.snippet) }) else {
				Issue.record("Missing \(probe.label) OCR line containing \(probe.snippet)")
				continue
			}
			
			guard let startIndex = selectionLines.firstIndex(where: { $0.combinedText.contains(probe.snippet) }) else {
				Issue.record("Missing \(probe.label) selection line containing \(probe.snippet)")
				continue
			}
			
			let endIndex = min(selectionLines.count, startIndex + probe.selectionSpan)
			let block = Array(selectionLines[startIndex..<endIndex])
			let selectionText = block.map(\.combinedText).joined(separator: " ")
			let selectionFragments = block.flatMap { $0.fragments.map(\.string) }
			let selectionTokens = normalizedTokens(from: selectionText)
			let ocrTokens = normalizedTokens(from: ocrLine.combinedText)
			let similarity = jaccardSimilarity(between: selectionTokens, and: ocrTokens)
			
			let formattedSimilarity = String(format: "%.2f", similarity)
			print("Comparison for \(probe.label) — similarity \(formattedSimilarity)")
			print("OCR text       : \(ocrLine.combinedText)")
			print("Selection text : \(selectionText)")
			print("Selection fragments: \(selectionFragments)")
			print("OCR fragments      : \(ocrLine.fragments.map { $0.string })\n")
			
			if probe.label == "transaction row" {
				#expect(
					selectionFragments.count >= ocrLine.fragments.count - 1,
					"Expected selection fragments to follow the column structure for \(probe.label)"
				)
			}
			
			#expect(
				similarity >= probe.similarityThreshold,
				"Selection text diverges for \(probe.label) (similarity \(similarity))"
			)
		}
		#else
		#expect(true, "Vision not available; skipping Mastercard comparison test")
		#endif
	}
	
	@Test func testMasterCardTransactionWhitespaceCharacters() throws {
		let pdfPath = ("~/Downloads/MASTERCARD.pdf" as NSString).expandingTildeInPath
		let fileExists = FileManager.default.fileExists(atPath: pdfPath)
		#expect(fileExists, "The Mastercard fixture must exist at \(pdfPath)")
		guard fileExists, let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else { return }
		guard let page = document.page(at: 1), let pageString = page.string else {
			Issue.record("Unable to access page 2 text for Mastercard PDF")
			return
		}
		
		let target = "4 29.10 30.10 CRV*BUPPI Bory Mall Br Dienstleistung Vilnius"
		let nsString = pageString as NSString
		let range = nsString.range(of: target)
		#expect(range.location != NSNotFound, "Target transaction line not found in PDF text")
		guard range.location != NSNotFound else { return }
		
		let substring = nsString.substring(with: range)
		let scalarPairs = substring.unicodeScalars.map { ($0, $0.value) }
		print("Transaction substring scalars: \(scalarPairs)")
		
		for offset in 0..<range.length {
			let globalIndex = range.location + offset
			let char = nsString.character(at: globalIndex)
			let scalar = UnicodeScalar(char)
			let bounds = resolvedBounds(for: page, atCharacterIndex: globalIndex)
			let scalarDescription = scalar.map(String.init) ?? "?"
			print("char[\(offset)] \(scalarDescription) (\(char)) bounds: \(bounds)")
		}
		
		let whitespaceScalars = substring.unicodeScalars.filter { CharacterSet.whitespacesAndNewlines.contains($0) }
		let uniqueWhitespaceValues = Set(whitespaceScalars.map { $0.value })
		#expect(uniqueWhitespaceValues == [32], "Expected only ASCII spaces in transaction substring, found \(uniqueWhitespaceValues)")
		}
		
	}

private func tableCellCount(_ table: DocumentBlock.Table) -> Int {
	table.rows.reduce(0) { $0 + $1.count }
}

private func normalizedCellText(_ text: String) -> String {
	text.components(separatedBy: .whitespacesAndNewlines)
		.filter { !$0.isEmpty }
		.joined(separator: " ")
}

private func nonEmptyCellCount(in row: [DocumentBlock.Table.Cell]) -> Int {
	row.map { normalizedCellText($0.text) }.filter { !$0.isEmpty }.count
}

private func clampedRect(_ rect: CGRect, to limits: CGRect) -> CGRect {
	let x = max(limits.minX, min(rect.minX, limits.maxX))
	let y = max(limits.minY, min(rect.minY, limits.maxY))
	let maxWidth = max(0, limits.maxX - x)
	let maxHeight = max(0, limits.maxY - y)
	let width = min(rect.width, maxWidth)
	let height = min(rect.height, maxHeight)
	return CGRect(x: x, y: y, width: width, height: height)
}

private func normalizedTokens(from text: String) -> [String] {
	let punctuation = CharacterSet(charactersIn: ",.;:()[]+")
	return text
		.lowercased()
		.components(separatedBy: .whitespacesAndNewlines)
		.map { $0.trimmingCharacters(in: punctuation) }
		.map { $0.replacingOccurrences(of: "-", with: "") }
		.map { $0.replacingOccurrences(of: "_", with: "") }
		.filter { !$0.isEmpty }
}

private func tokenFrequency(from tokens: [String]) -> [String: Int] {
	var frequencies = [String: Int]()
	for token in tokens {
		frequencies[token, default: 0] += 1
	}
	return frequencies
}

private func jaccardSimilarity(between lhs: [String], and rhs: [String]) -> Double {
	let lhsFrequency = tokenFrequency(from: lhs)
	let rhsFrequency = tokenFrequency(from: rhs)
	let keys = Set(lhsFrequency.keys).union(rhsFrequency.keys)
	guard !keys.isEmpty else { return 0 }
	
	var intersection = 0
	var union = 0
	for key in keys {
		let lhsCount = lhsFrequency[key] ?? 0
		let rhsCount = rhsFrequency[key] ?? 0
		intersection += min(lhsCount, rhsCount)
		union += max(lhsCount, rhsCount)
	}
	
	return union == 0 ? 0 : Double(intersection) / Double(union)
}

private func writePNG(_ cgImage: CGImage, to url: URL) throws {
	guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
		throw NSError(domain: "SwiftTextOCRTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unable to create image destination at \(url.path)"])
	}
	CGImageDestinationAddImage(destination, cgImage, nil)
	if !CGImageDestinationFinalize(destination) {
		throw NSError(domain: "SwiftTextOCRTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to save image at \(url.path)"])
	}
}

private func logCharacterBounds(for text: String, in page: PDFPage, label: String) {
	guard let pageString = page.string else {
		print("No page string available for \(label)")
		return
	}
	
	let nsString = pageString as NSString
	let range = nsString.range(of: text)
	if range.location == NSNotFound {
		print("Unable to locate text for \(label)")
		return
	}
	
	print("Character bounds for \(label):")
	for offset in 0..<range.length {
		let index = range.location + offset
		let character = nsString.character(at: index)
		let scalar = UnicodeScalar(character).map(String.init) ?? "?"
		let bounds = resolvedBounds(for: page, atCharacterIndex: index)
		print("  char[\(offset)] \(scalar) (\(character)) bounds: \(bounds)")
	}
}

private func resolvedBounds(for page: PDFPage, atCharacterIndex index: Int) -> CGRect {
	let range = NSRange(location: index, length: 1)
	if let selection = page.selection(for: range) {
		let bounds = selection.bounds(for: page)
		if !bounds.isNull && !bounds.isEmpty {
			return bounds
		}
	}
	return page.characterBounds(at: index)
}

#if canImport(Vision)
private func renderOverlay(for page: PDFPage, blocks: [DocumentBlock], lines: [TextLine], rectangles: [CGRect] = [], dpi: CGFloat, to url: URL) throws {
	let (pageImage, pageSize) = try page.renderedPageImage(dpi: dpi)
	let pdfSize = page.bounds(for: .mediaBox).size
	
	let colorSpace = CGColorSpaceCreateDeviceRGB()
	guard let context = CGContext(
		data: nil,
		width: Int(pageSize.width),
		height: Int(pageSize.height),
		bitsPerComponent: 8,
		bytesPerRow: 0,
		space: colorSpace,
		bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
	) else {
		throw NSError(domain: "SwiftTextOCRTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create overlay context"])
	}
	
	context.draw(pageImage, in: CGRect(origin: .zero, size: pageSize))
	
	context.setLineWidth(2.0)
	
	// Draw raw rectangle detections in blue with dashed strokes
	if !rectangles.isEmpty {
		context.saveGState()
		context.setStrokeColor(CGColor(red: 0, green: 0.6, blue: 1, alpha: 0.7))
		context.setLineWidth(1.5)
		context.setLineDash(phase: 0, lengths: [6, 4])
		for rect in rectangles {
			let converted = CGRect(
				x: rect.minX,
				y: pageSize.height - rect.maxY,
				width: rect.width,
				height: rect.height
			)
			context.stroke(converted)
		}
		context.restoreGState()
	}
	
	context.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.8))
	
	for block in blocks {
		let rect = block.bounds
		let converted = CGRect(
			x: rect.minX,
			y: pageSize.height - rect.maxY,
			width: rect.width,
			height: rect.height
		)
		context.stroke(converted)
	}
	
	// Draw OCR/PDFKit text lines in green
	context.setStrokeColor(CGColor(red: 0, green: 1, blue: 0, alpha: 0.6))
	for line in lines {
		let bounds = line.fragments.reduce(line.fragments.first?.bounds ?? .zero) { partial, fragment in
			partial.union(fragment.bounds)
		}
		let converted = scaleAndFlip(rect: bounds, pdfSize: pdfSize, targetSize: pageSize)
		context.stroke(converted)
	}
	
	guard let cgImage = context.makeImage() else {
		throw NSError(domain: "SwiftTextOCRTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to finalize overlay image"])
	}
	
	guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
		throw NSError(domain: "SwiftTextOCRTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to create image destination at \(url.path)"])
	}
	CGImageDestinationAddImage(destination, cgImage, nil)
	if !CGImageDestinationFinalize(destination) {
		throw NSError(domain: "SwiftTextOCRTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to save image at \(url.path)"])
	}
}

private func scaleAndFlip(rect: CGRect, pdfSize: CGSize, targetSize: CGSize) -> CGRect {
	let scaleX = targetSize.width / pdfSize.width
	let scaleY = targetSize.height / pdfSize.height
	let x = rect.minX * scaleX
	let width = rect.width * scaleX
	let maxY = rect.maxY * scaleY
	let height = rect.height * scaleY
	let y = targetSize.height - maxY
	return CGRect(x: x, y: y, width: width, height: height)
}
#endif
