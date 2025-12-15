//
//  SwiftTextPDFTests.swift
//  SwiftText
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

@testable import SwiftTextPDF

struct SwiftTextPDFTests {
	
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
		
		let pngPath = ("~/Downloads/test.png" as NSString).expandingTildeInPath
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
		
		let pngPath = ("~/Downloads/test.png" as NSString).expandingTildeInPath
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
			print("Missing OCR lines from segmented transcript:\n\(missingLines.joined(separator: "\n"))")
		}
		
		#expect(missingLines.isEmpty, "Segmented transcript should include all OCR-recognized lines")
		#else
		#expect(true, "Vision not available; skipping PNG OCR comparison test")
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
		#expect(lines[0].combinedText == "Hello World")
		#expect(lines[1].combinedText == "Second line")
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
		throw NSError(domain: "SwiftTextPDFTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create overlay context"])
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
		throw NSError(domain: "SwiftTextPDFTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to finalize overlay image"])
	}
	
	guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
		throw NSError(domain: "SwiftTextPDFTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to create image destination at \(url.path)"])
	}
	CGImageDestinationAddImage(destination, cgImage, nil)
	if !CGImageDestinationFinalize(destination) {
		throw NSError(domain: "SwiftTextPDFTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to save image at \(url.path)"])
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
