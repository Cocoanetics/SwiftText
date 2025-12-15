//
//  PDFPage+DocumentBlocks.swift
//  SwiftTextPDF
//
//  Created by OpenAI Codex on 11.12.24.
//

import Foundation
import PDFKit
#if canImport(Vision)
import Vision
#endif

/// Errors thrown while extracting structured document blocks from a page.
public enum DocumentScannerError: Error, CustomStringConvertible {
	case visionUnavailable
	case unrecognizedDocument
	case requestFailed(Error)
	
	public var description: String {
		switch self {
		case .visionUnavailable:
			return "Vision is not available on this platform."
		case .unrecognizedDocument:
			return "The renderer could not detect any document structure."
		case .requestFailed(let error):
			return "Vision request failed: \(error.localizedDescription)"
		}
	}
}

#if canImport(Vision)
extension PDFPage {
	public func documentBlocks(dpi: CGFloat = 300) async throws -> [DocumentBlock] {
		return try await documentBlocksWithImages(dpi: dpi).blocks
	}
	
	public func documentBlocksWithImages(dpi: CGFloat = 300) async throws -> (blocks: [DocumentBlock], images: [DocumentImage]) {
		guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else {
			throw DocumentScannerError.visionUnavailable
		}
		let (cgImage, pageSize) = try renderedPageImage(dpi: dpi)
		
		let recognizeRequest = RecognizeDocumentsRequest()
		let observations = try await recognizeRequest.perform(on: cgImage, orientation: nil)
		
		guard let document = observations.first?.document else {
			throw DocumentScannerError.unrecognizedDocument
		}
		
		let extractor = DocumentBlockExtractor(image: cgImage, pageSize: pageSize, allowStandaloneSupplementation: true)
		return try extractor.extractBlocksWithImages(from: document)
	}
	
	/// Detects rectangular regions on the rendered page. Coordinates are returned in page space (origin at the top-left).
	public func detectedRectangles(dpi: CGFloat = 300) throws -> [CGRect] {
		guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else {
			throw DocumentScannerError.visionUnavailable
		}
		let (cgImage, pageSize) = try renderedPageImage(dpi: dpi)
		return try detectRectangles(in: cgImage, pageSize: pageSize)
	}
}

public func documentBlocks(from cgImage: CGImage) async throws -> (blocks: [DocumentBlock], images: [DocumentImage]) {
	guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else {
		throw DocumentScannerError.visionUnavailable
	}
	let pageSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
	let recognizeRequest = RecognizeDocumentsRequest()
	let observations = try await recognizeRequest.perform(on: cgImage, orientation: nil)
	
	guard let document = observations.first?.document else {
		throw DocumentScannerError.unrecognizedDocument
	}
	
	let extractor = DocumentBlockExtractor(image: cgImage, pageSize: pageSize)
	return try extractor.extractBlocksWithImages(from: document)
}

/// Detects rectangular regions within a CGImage. Coordinates are returned in image space (origin at the top-left).
public func detectedRectangles(from cgImage: CGImage) throws -> [CGRect] {
	guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else {
		throw DocumentScannerError.visionUnavailable
	}
	let pageSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
	return try detectRectangles(in: cgImage, pageSize: pageSize)
}
#else
extension PDFPage {
	public func documentBlocks(dpi: CGFloat = 300) async throws -> [DocumentBlock] {
		throw DocumentScannerError.visionUnavailable
	}
}
#endif

#if canImport(Vision)
@available(iOS 26.0, tvOS 26.0, macOS 26.0, *)
struct DocumentBlockExtractor {
	let image: CGImage
	let pageSize: CGSize
	let allowStandaloneSupplementation: Bool
	
	init(image: CGImage, pageSize: CGSize, allowStandaloneSupplementation: Bool = true) {
		self.image = image
		self.pageSize = pageSize
		self.allowStandaloneSupplementation = allowStandaloneSupplementation
	}
	
	func extractBlocks(from container: DocumentObservation.Container) throws -> [DocumentBlock] {
		let ocrLines = allowStandaloneSupplementation ? recognizeTextLines() : []
		var usedOCRLineIDs = Set<Int>()
		var usedOCRTexts = Set<String>()
		
		var structuredBlocks = gatherStructuredBlocks(from: container, ocrLines: ocrLines, usedOCRLineIDs: &usedOCRLineIDs, usedOCRTexts: &usedOCRTexts)
		let imageResult = try detectImageBlocks(excluding: structuredBlocks, captureImages: false)
		
		let remainingLines = ocrLines.filter { !usedOCRLineIDs.contains($0.id) }
		if allowStandaloneSupplementation && !remainingLines.isEmpty {
			let standaloneParagraphs = makeStandaloneParagraphBlocks(from: remainingLines, excluding: structuredBlocks, existingTexts: textSet(from: structuredBlocks))
			structuredBlocks.append(contentsOf: standaloneParagraphs)
		}
		
		structuredBlocks.append(contentsOf: imageResult.blocks)
		structuredBlocks.sort(by: isInReadingOrder(_:_:))
		return structuredBlocks
	}
	
	func extractBlocksWithImages(from container: DocumentObservation.Container) throws -> (blocks: [DocumentBlock], images: [DocumentImage]) {
		let ocrLines = allowStandaloneSupplementation ? recognizeTextLines() : []
		var usedOCRLineIDs = Set<Int>()
		var usedOCRTexts = Set<String>()
		
		var structuredBlocks = gatherStructuredBlocks(from: container, ocrLines: ocrLines, usedOCRLineIDs: &usedOCRLineIDs, usedOCRTexts: &usedOCRTexts)
		let imageResult = try detectImageBlocks(excluding: structuredBlocks, captureImages: true)
		
		let remainingLines = ocrLines.filter { !usedOCRLineIDs.contains($0.id) }
		if allowStandaloneSupplementation && !remainingLines.isEmpty {
			let standaloneParagraphs = makeStandaloneParagraphBlocks(from: remainingLines, excluding: structuredBlocks, existingTexts: textSet(from: structuredBlocks))
			structuredBlocks.append(contentsOf: standaloneParagraphs)
		}
		
		structuredBlocks.append(contentsOf: imageResult.blocks)
		structuredBlocks.sort(by: isInReadingOrder(_:_:))
		return (structuredBlocks, imageResult.images)
	}
	
	private func gatherStructuredBlocks(from container: DocumentObservation.Container, ocrLines: [OCRLine], usedOCRLineIDs: inout Set<Int>, usedOCRTexts: inout Set<String>) -> [DocumentBlock] {
		var blocks = [DocumentBlock]()
		
		for list in container.lists {
			let rect = list.boundingRegion.rect(in: pageSize)
			let listBlock = makeList(from: list, ocrLines: ocrLines, usedOCRLineIDs: &usedOCRLineIDs, usedOCRTexts: &usedOCRTexts)
			blocks.append(DocumentBlock(bounds: rect, kind: .list(listBlock)))
			consumeLines(in: rect, ocrLines: ocrLines, usedOCRLineIDs: &usedOCRLineIDs, usedOCRTexts: &usedOCRTexts, tolerance: 12)
		}
		
		for table in container.tables {
			let rect = table.boundingRegion.rect(in: pageSize)
			let tableBlock = makeTable(from: table, ocrLines: ocrLines, usedOCRLineIDs: &usedOCRLineIDs, usedOCRTexts: &usedOCRTexts)
			blocks.append(DocumentBlock(bounds: rect, kind: .table(tableBlock)))
			consumeLines(in: rect, ocrLines: ocrLines, usedOCRLineIDs: &usedOCRLineIDs, usedOCRTexts: &usedOCRTexts, tolerance: 12)
		}
		
		let listTableBounds = blocks.map(\.bounds)
		let listTableTexts = textSet(from: blocks)
		
		for paragraph in container.paragraphs {
			let rect = paragraph.boundingRegion.rect(in: pageSize)
			let overlapsListTable = listTableBounds.contains { overlapRatio(between: $0, and: rect) > 0.25 }
			if overlapsListTable { continue }
			
			if let paragraphBlock = makeParagraph(from: paragraph, ocrLines: ocrLines, usedOCRLineIDs: &usedOCRLineIDs, usedOCRTexts: &usedOCRTexts) {
				let trimmedText = paragraphBlock.text.trimmingCharacters(in: .whitespacesAndNewlines)
				let normalizedParagraph = normalizedComparableText(trimmedText)
				if listTableTexts.contains(normalizedParagraph) { continue }
				blocks.append(DocumentBlock(bounds: rect, kind: .paragraph(paragraphBlock)))
				consumeLines(in: rect, ocrLines: ocrLines, usedOCRLineIDs: &usedOCRLineIDs, usedOCRTexts: &usedOCRTexts, tolerance: 8)
			}
		}
		
		return blocks
	}
	
	private func makeParagraph(from text: DocumentObservation.Container.Text, ocrLines: [OCRLine], usedOCRLineIDs: inout Set<Int>, usedOCRTexts: inout Set<String>) -> DocumentBlock.Paragraph? {
		let trimmed = text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
		let rect = text.boundingRegion.rect(in: pageSize)
		
		let paragraphLines = linesOverlapping(rect, in: ocrLines, usedOCRLineIDs: &usedOCRLineIDs, usedOCRTexts: &usedOCRTexts)
		if !paragraphLines.isEmpty {
			let docLines = paragraphLines.map { DocumentBlock.TextLine(text: $0.text, bounds: $0.bounds) }
			let combined = docLines.map(\.text).joined(separator: "\n")
			return DocumentBlock.Paragraph(text: combined, lines: docLines)
		}
		
		if !trimmed.isEmpty && usedOCRTexts.contains(where: { $0.contains(trimmed) }) {
			return nil
		}
		
		let mappedLines = text.lines.map { observation -> DocumentBlock.TextLine in
			let candidate = observation.topCandidates(1).first?.string ?? trimmed
			let normalizedRect = convertNormalizedRect(observation.boundingBox, in: pageSize)
			return DocumentBlock.TextLine(text: candidate.trimmingCharacters(in: .whitespacesAndNewlines), bounds: normalizedRect)
		}
		
		let fallbackLines = mappedLines.isEmpty
			? [DocumentBlock.TextLine(text: trimmed, bounds: rect)]
			: mappedLines
		
		return DocumentBlock.Paragraph(text: trimmed, lines: fallbackLines)
	}
	
	private func makeList(from list: DocumentObservation.Container.List, ocrLines: [OCRLine], usedOCRLineIDs: inout Set<Int>, usedOCRTexts: inout Set<String>) -> DocumentBlock.List {
		var items = [DocumentBlock.List.Item]()
		
		for item in list.items {
			let paragraphs = paragraphs(from: item.content, ocrLines: ocrLines, usedOCRLineIDs: &usedOCRLineIDs, usedOCRTexts: &usedOCRTexts)
			let combinedText: String
			let combinedLines: [DocumentBlock.TextLine]
			
			if paragraphs.isEmpty {
				let cleaned = cleanListItemText(item.itemString, marker: item.markerString)
				combinedText = cleaned
				combinedLines = [DocumentBlock.TextLine(text: cleaned, bounds: item.content.boundingRegion.rect(in: pageSize))]
			} else {
				let joined = paragraphs.map(\.text).joined(separator: "\n")
				combinedText = cleanListItemText(joined, marker: item.markerString)
				let rawLines = paragraphs.flatMap(\.lines).map {
					DocumentBlock.TextLine(
						text: cleanListItemText($0.text, marker: item.markerString),
						bounds: $0.bounds
					)
				}
				combinedLines = deduplicatedLines(rawLines)
			}
			let rect = item.content.boundingRegion.rect(in: pageSize)
			
			let finalLines = combinedLines.isEmpty
				? [DocumentBlock.TextLine(text: combinedText, bounds: rect)]
				: combinedLines
			
			let finalText = finalLines.map(\.text).joined(separator: "\n")
			
			items.append(
				DocumentBlock.List.Item(
					text: finalText,
					markerString: item.markerString,
					bounds: rect,
					lines: finalLines
				)
			)
		}
		
		let marker: DocumentBlock.List.Marker
		if let firstItem = list.items.first {
			marker = resolveMarker(from: firstItem.markerType, fallback: firstItem.markerString)
		} else {
			marker = .custom("")
		}
		
		return DocumentBlock.List(marker: marker, items: items)
	}
	
	private func makeTable(from table: DocumentObservation.Container.Table, ocrLines: [OCRLine], usedOCRLineIDs: inout Set<Int>, usedOCRTexts: inout Set<String>) -> DocumentBlock.Table {
		let rows: [[DocumentBlock.Table.Cell]] = table.rows.map { row in
			row.map { cell in
				let paragraphs = paragraphs(from: cell.content, ocrLines: ocrLines, usedOCRLineIDs: &usedOCRLineIDs, usedOCRTexts: &usedOCRTexts)
				let text = paragraphs.map(\.text).joined(separator: "\n")
				let rect = cell.content.boundingRegion.rect(in: pageSize)
				let lines = paragraphs.flatMap(\.lines)
				return DocumentBlock.Table.Cell(
					rowRange: cell.rowRange,
					columnRange: cell.columnRange,
					text: text,
					bounds: rect,
					lines: lines.isEmpty ? [DocumentBlock.TextLine(text: text, bounds: rect)] : lines
				)
			}
		}
		
		return DocumentBlock.Table(rows: rows)
	}
	
	private func paragraphs(from container: DocumentObservation.Container, ocrLines: [OCRLine], usedOCRLineIDs: inout Set<Int>, usedOCRTexts: inout Set<String>) -> [DocumentBlock.Paragraph] {
		if container.paragraphs.isEmpty {
			let trimmed = container.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { return [] }
			guard let paragraph = makeParagraph(from: container.text, ocrLines: ocrLines, usedOCRLineIDs: &usedOCRLineIDs, usedOCRTexts: &usedOCRTexts) else { return [] }
			return [paragraph]
		} else {
			return container.paragraphs.compactMap { makeParagraph(from: $0, ocrLines: ocrLines, usedOCRLineIDs: &usedOCRLineIDs, usedOCRTexts: &usedOCRTexts) }
		}
	}
	
	private func resolveMarker(from markerType: DocumentObservation.Container.List.Marker?, fallback: String) -> DocumentBlock.List.Marker {
		guard let markerType else {
			return .custom(fallback)
		}
		
		switch markerType {
		case .bullet:
			return .bullet
		case .hyphen:
			return .hyphen
		case .lowercaseLatin:
			return .lowercaseLatin
		case .uppercaseLatin:
			return .uppercaseLatin
		case .decimal:
			return .decimal
		case .decorativeDecimal:
			return .decorativeDecimal
		case .compositeDecimal:
			return .compositeDecimal
		@unknown default:
			return .custom(fallback)
		}
	}
	
	private func detectImageBlocks(excluding structured: [DocumentBlock], captureImages: Bool) throws -> (blocks: [DocumentBlock], images: [DocumentImage]) {
		let rectangles = try detectRectangles(in: image, pageSize: pageSize)
		
		guard !rectangles.isEmpty else {
			return ([], [])
		}
		
		let structuredBounds = structured.map(\.bounds)
		let pageArea = pageSize.width * pageSize.height
		let minimumImageArea = pageArea * 0.01
		let pageBounds = CGRect(origin: .zero, size: pageSize)
		
		var imageBlocks = [DocumentBlock]()
		var images = [DocumentImage]()
		
		for rectangleBounds in rectangles {
			let rect = rectangleBounds
			let area = rect.width * rect.height
			
			guard area >= minimumImageArea,
			      rect.width < pageSize.width * 0.95,
			      rect.height < pageSize.height * 0.95 else {
				continue
			}
			
			let overlapsStructured = structuredBounds.contains { overlapRatio(between: $0, and: rect) > 0.35 }
			if overlapsStructured {
				continue
			}
			
			let overlapsImages = imageBlocks.contains { overlapRatio(between: $0.bounds, and: rect) > 0.65 }
			if overlapsImages {
				continue
			}
			
			imageBlocks.append(DocumentBlock(bounds: rect, kind: .image(.init(caption: nil))))
			
			if captureImages, let cropped = image.cropping(to: rect.integral.clamped(to: pageBounds)) {
				images.append(DocumentImage(bounds: rect, image: cropped))
			}
		}
		
		return (imageBlocks, images)
	}
	
	private func recognizeTextLines() -> [OCRLine] {
		guard let textLines = try? image.performOCR(imageSize: pageSize) else {
			return []
		}
		
		return textLines.enumerated().map { index, line in
			let rawBounds = line.fragments.reduce(line.fragments.first?.bounds ?? .zero) { partialResult, fragment in
				partialResult.union(fragment.bounds)
			}
			let normalized = Vision.NormalizedRect(
				x: rawBounds.minX / pageSize.width,
				y: rawBounds.minY / pageSize.height,
				width: rawBounds.width / pageSize.width,
				height: rawBounds.height / pageSize.height
			)
			let bounds = normalized.toImageCoordinates(from: .fullImage, imageSize: pageSize, origin: .upperLeft)
			return OCRLine(id: index, text: line.combinedText, bounds: bounds)
		}.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
		.sorted { lhs, rhs in
			isInReadingOrder(lhs.bounds, rhs.bounds)
		}
	}
	
	private func linesOverlapping(_ rect: CGRect, in lines: [OCRLine], usedOCRLineIDs: inout Set<Int>, usedOCRTexts: inout Set<String>) -> [OCRLine] {
		let tolerance = max(rect.height * 0.2, 12)
		let matched = lines
			.filter { line in
				guard !usedOCRLineIDs.contains(line.id) else { return false }
				let center = line.bounds.center
				let verticallyAligned = center.y >= rect.minY - tolerance && center.y <= rect.maxY + tolerance
				let horizontallyAligned = line.bounds.maxX >= rect.minX - tolerance && line.bounds.minX <= rect.maxX + tolerance
				return verticallyAligned && horizontallyAligned
			}
			.sorted { lhs, rhs in
				isInReadingOrder(lhs.bounds, rhs.bounds)
			}
		matched.forEach {
			usedOCRLineIDs.insert($0.id)
			usedOCRTexts.insert($0.text)
		}
		return matched
	}
	
	private func consumeLines(in rect: CGRect, ocrLines: [OCRLine], usedOCRLineIDs: inout Set<Int>, usedOCRTexts: inout Set<String>, tolerance: CGFloat) {
		for line in ocrLines {
			if usedOCRLineIDs.contains(line.id) { continue }
			let center = line.bounds.center
			let verticallyAligned = center.y >= rect.minY - tolerance && center.y <= rect.maxY + tolerance
			let horizontallyAligned = line.bounds.maxX >= rect.minX - tolerance && line.bounds.minX <= rect.maxX + tolerance
			if verticallyAligned && horizontallyAligned {
				usedOCRLineIDs.insert(line.id)
				usedOCRTexts.insert(line.text)
			}
		}
	}
	
	private func isInReadingOrder(_ lhs: DocumentBlock, _ rhs: DocumentBlock) -> Bool {
		isInReadingOrder(lhs.bounds, rhs.bounds)
	}
	
	private func isInReadingOrder(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
		let verticalDelta = lhs.minY - rhs.minY
		let tolerance = max(CGFloat(4), max(lhs.height, rhs.height) * 0.25)
		
		if abs(verticalDelta) > tolerance {
			return verticalDelta < 0
		}
		
		return lhs.minX < rhs.minX
	}
	
	private func makeStandaloneParagraphBlocks(from lines: [OCRLine], excluding existing: [DocumentBlock], existingTexts: Set<String>) -> [DocumentBlock] {
		guard !lines.isEmpty else { return [] }
		
		let sorted = lines.sorted { isInReadingOrder($0.bounds, $1.bounds) }
		var groups: [[OCRLine]] = []
		let existingBounds = existing.map(\.bounds)
		
		for line in sorted {
			let overlapsExisting = existingBounds.contains { overlapRatio(between: $0, and: line.bounds) > 0.2 }
			if overlapsExisting { continue }
			if existingTexts.contains(normalizedComparableText(line.text)) {
				continue
			}
			
			if var current = groups.last, isAdjacent(current.last!, line) {
				current.append(line)
				groups[groups.count - 1] = current
			} else {
				groups.append([line])
			}
		}
		
		return groups.map { group in
			let docLines = group.map { DocumentBlock.TextLine(text: $0.text, bounds: $0.bounds) }
			let text = docLines.map(\.text).joined(separator: "\n")
			let bounds = group.reduce(group[0].bounds) { $0.union($1.bounds) }
			return DocumentBlock(bounds: bounds, kind: .paragraph(.init(text: text, lines: docLines)))
		}
	}
	
	private func isAdjacent(_ lhs: OCRLine, _ rhs: OCRLine) -> Bool {
		let verticalGap = rhs.bounds.minY - lhs.bounds.maxY
		let maxHeight = max(lhs.bounds.height, rhs.bounds.height)
		return verticalGap <= max(maxHeight * 1.2, 12)
	}
	
	private func cleanListItemText(_ text: String, marker: String) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return trimmed }
		
		if !marker.isEmpty {
			let escaped = NSRegularExpression.escapedPattern(for: marker)
			let pattern = "^\(escaped)[.)\\s]*"
			if let range = trimmed.range(of: pattern, options: .regularExpression) {
				let cleaned = trimmed.replacingCharacters(in: range, with: "")
				return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
			}
		}
		
		let pattern = #"^[0-9]+[.)\s]+"#
		if let range = trimmed.range(of: pattern, options: .regularExpression) {
			let cleaned = trimmed.replacingCharacters(in: range, with: "")
			return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		
		return trimmed
	}
	
	private func deduplicatedLines(_ lines: [DocumentBlock.TextLine]) -> [DocumentBlock.TextLine] {
		var seen = Set<String>()
		var result = [DocumentBlock.TextLine]()
		
		for line in lines {
			let key = normalizedComparableText(line.text)
			guard !key.isEmpty else { continue }
			if seen.contains(key) { continue }
			seen.insert(key)
			result.append(line)
		}
		
		return result
	}
}

private func detectRectangles(in cgImage: CGImage, pageSize: CGSize) throws -> [CGRect] {
	let rectangleRequest = VNDetectRectanglesRequest()
	rectangleRequest.maximumObservations = 24
	rectangleRequest.minimumAspectRatio = 0.1
	rectangleRequest.minimumSize = 0.02
	rectangleRequest.minimumConfidence = 0.3
	
	let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
	
	do {
		try handler.perform([rectangleRequest])
	} catch {
		throw DocumentScannerError.requestFailed(error)
	}
	
	guard let rectangles = rectangleRequest.results, !rectangles.isEmpty else {
		return []
	}
	
	let pageBounds = CGRect(origin: .zero, size: pageSize)
	
	return rectangles.compactMap { observation in
		let rect = convertNormalizedBoundingBox(observation.boundingBox, in: pageSize)
		let clamped = rect.integral.clamped(to: pageBounds)
		guard clamped.width > 0, clamped.height > 0 else { return nil }
		return clamped
	}
}

private struct OCRLine {
	let id: Int
	let text: String
	let bounds: CGRect
}

private func textSet(from blocks: [DocumentBlock]) -> Set<String> {
	var texts = Set<String>()
	for block in blocks {
		switch block.kind {
		case .paragraph(let paragraph):
			paragraph.lines.forEach { texts.insert(normalizedComparableText($0.text)) }
			texts.insert(normalizedComparableText(paragraph.text))
		case .list(let list):
			for item in list.items {
				texts.insert(normalizedComparableText(item.text))
				item.lines.forEach { texts.insert(normalizedComparableText($0.text)) }
			}
		case .table(let table):
			for row in table.rows {
				for cell in row {
					texts.insert(normalizedComparableText(cell.text))
					cell.lines.forEach { texts.insert(normalizedComparableText($0.text)) }
				}
			}
		case .image:
			break
		}
	}
	return texts.filter { !$0.isEmpty }
}

private extension CGRect {
	var center: CGPoint {
		CGPoint(x: midX, y: midY)
	}
	
	func clamped(to limits: CGRect) -> CGRect {
		let x = max(limits.minX, min(minX, limits.maxX))
		let y = max(limits.minY, min(minY, limits.maxY))
		let maxWidth = max(0, limits.maxX - x)
		let maxHeight = max(0, limits.maxY - y)
		let width = min(size.width, maxWidth)
		let height = min(size.height, maxHeight)
		return CGRect(x: x, y: y, width: width, height: height)
	}
}

private func normalizedComparableText(_ text: String) -> String {
	let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
	let pattern = #"^[0-9]+[.)\s]+"#
	if let range = trimmed.range(of: pattern, options: .regularExpression) {
		return trimmed.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
	}
	return trimmed
}

@available(iOS 26.0, tvOS 26.0, macOS 26.0, *)
private func convertNormalizedRect(_ rect: Vision.NormalizedRect, in pageSize: CGSize) -> CGRect {
	let converted = rect.toImageCoordinates(from: .fullImage, imageSize: pageSize, origin: .lowerLeft)
	return CGRect(
		x: converted.minX,
		y: pageSize.height - converted.maxY,
		width: converted.width,
		height: converted.height
	)
}

private func convertNormalizedBoundingBox(_ rect: CGRect, in pageSize: CGSize) -> CGRect {
	return CGRect(
		x: rect.minX * pageSize.width,
		y: (1.0 - rect.maxY) * pageSize.height,
		width: rect.width * pageSize.width,
		height: rect.height * pageSize.height
	)
}

private func overlapRatio(between first: CGRect, and second: CGRect) -> CGFloat {
	let intersection = first.intersection(second)
	guard !intersection.isNull && !intersection.isInfinite else {
		return 0
	}
	
	let intersectionArea = intersection.width * intersection.height
	let referenceArea = min(first.width * first.height, second.width * second.height)
	guard referenceArea > 0 else {
		return 0
	}
	
	return intersectionArea / referenceArea
}

@available(iOS 26.0, tvOS 26.0, macOS 26.0, *)
private extension Vision.NormalizedRegion {
	func rect(in pageSize: CGSize) -> CGRect {
		convertNormalizedBoundingBox(normalizedPath.boundingBox, in: pageSize)
	}
}
#endif
