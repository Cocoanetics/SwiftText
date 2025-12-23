//
//  DocumentSemantics.swift
//  SwiftTextOCR
//
//  Created by OpenAI Codex on 20.12.24.
//

import CoreGraphics
import Foundation
#if canImport(Vision)
import Vision
#endif

/// Represents a rectangle normalized to the unit square using a top-left origin.
public struct NormalizedRect: Equatable, Sendable {
	public var minX: CGFloat
	public var minY: CGFloat
	public var width: CGFloat
	public var height: CGFloat
	
	public init(minX: CGFloat, minY: CGFloat, width: CGFloat, height: CGFloat) {
		self.minX = minX
		self.minY = minY
		self.width = width
		self.height = height
	}
	
	public static let zero = NormalizedRect(minX: 0, minY: 0, width: 0, height: 0)
	
	public var maxX: CGFloat { minX + width }
	public var maxY: CGFloat { minY + height }
	
	public var center: CGPoint {
		CGPoint(x: minX + width / 2, y: minY + height / 2)
	}
	
	public func clamped() -> NormalizedRect {
		let clampedMinX = min(max(minX, 0), 1)
		let clampedMinY = min(max(minY, 0), 1)
		let clampedMaxX = min(max(maxX, 0), 1)
		let clampedMaxY = min(max(maxY, 0), 1)
		return NormalizedRect(
			minX: clampedMinX,
			minY: clampedMinY,
			width: max(0, clampedMaxX - clampedMinX),
			height: max(0, clampedMaxY - clampedMinY)
		)
	}
	
	public func expanded(by inset: CGFloat) -> NormalizedRect {
		let newMinX = minX - inset
		let newMinY = minY - inset
		let newMaxX = maxX + inset
		let newMaxY = maxY + inset
		return NormalizedRect(
			minX: newMinX,
			minY: newMinY,
			width: newMaxX - newMinX,
			height: newMaxY - newMinY
		).clamped()
	}
	
	public func intersects(_ other: NormalizedRect, tolerance: CGFloat = 0) -> Bool {
		let lhs = expanded(by: tolerance)
		let rhs = other.expanded(by: tolerance)
		
		let horizontal = lhs.minX <= rhs.maxX && lhs.maxX >= rhs.minX
		let vertical = lhs.minY <= rhs.maxY && lhs.maxY >= rhs.minY
		return horizontal && vertical
	}
	
	public func contains(_ point: CGPoint, tolerance: CGFloat = 0) -> Bool {
		let expandedRect = expanded(by: tolerance)
		return point.x >= expandedRect.minX &&
			point.x <= expandedRect.maxX &&
			point.y >= expandedRect.minY &&
			point.y <= expandedRect.maxY
	}
	
	public func overlapRatio(with other: NormalizedRect) -> CGFloat {
		let left = max(minX, other.minX)
		let right = min(maxX, other.maxX)
		let top = max(minY, other.minY)
		let bottom = min(maxY, other.maxY)
		
		guard right > left, bottom > top else { return 0 }
		let intersection = (right - left) * (bottom - top)
		let area = min(width * height, other.width * other.height)
		guard area > 0 else { return 0 }
		return intersection / area
	}
	
	public func scaled(to size: CGSize) -> CGRect {
		CGRect(
			x: minX * size.width,
			y: minY * size.height,
			width: width * size.width,
			height: height * size.height
		)
	}
	
	public func union(_ other: NormalizedRect) -> NormalizedRect {
		let minX = Swift.min(self.minX, other.minX)
		let minY = Swift.min(self.minY, other.minY)
		let maxX = Swift.max(self.maxX, other.maxX)
		let maxY = Swift.max(self.maxY, other.maxY)
		return NormalizedRect(
			minX: minX,
			minY: minY,
			width: max(0, maxX - minX),
			height: max(0, maxY - minY)
		).clamped()
	}
}

extension CGRect {
	public func normalized(in size: CGSize) -> NormalizedRect {
		guard size.width > 0, size.height > 0 else {
			return .zero
		}
		let minX = self.minX / size.width
		let minY = self.minY / size.height
		return NormalizedRect(
			minX: min(max(minX, 0), 1),
			minY: min(max(minY, 0), 1),
			width: min(max(width / size.width, 0), 1),
			height: min(max(height / size.height, 0), 1)
		)
	}
}

/// Encapsulates structured semantics extracted from a single rendered page (PDF page or image).
public struct DocumentSemantics {
	public let referenceSize: CGSize
	public let blocks: [NormalizedDocumentBlock]
	public let images: [DocumentImage]
	
	public init(referenceSize: CGSize, blocks: [NormalizedDocumentBlock], images: [DocumentImage]) {
		self.referenceSize = referenceSize
		self.blocks = blocks
		self.images = images
	}
}

/// Represents a semantic block with normalized geometry for block-level and nested elements.
public struct NormalizedDocumentBlock {
	public let block: DocumentBlock
	public let normalizedBounds: NormalizedRect
	public let listItems: [NormalizedListItem]
	public let tableRows: [[NormalizedTableCell]]
	
	public init(
		block: DocumentBlock,
		normalizedBounds: NormalizedRect,
		listItems: [NormalizedListItem] = [],
		tableRows: [[NormalizedTableCell]] = []
	) {
		self.block = block
		self.normalizedBounds = normalizedBounds
		self.listItems = listItems
		self.tableRows = tableRows
	}
	
	public struct NormalizedListItem {
		public let normalizedBounds: NormalizedRect
		public let item: DocumentBlock.List.Item
		
		public init(normalizedBounds: NormalizedRect, item: DocumentBlock.List.Item) {
			self.normalizedBounds = normalizedBounds
			self.item = item
		}
	}
	
	public struct NormalizedTableCell {
		public let normalizedBounds: NormalizedRect
		public let cell: DocumentBlock.Table.Cell
		
		public init(normalizedBounds: NormalizedRect, cell: DocumentBlock.Table.Cell) {
			self.normalizedBounds = normalizedBounds
			self.cell = cell
		}
	}
}

#if canImport(Vision)
@available(iOS 26.0, tvOS 26.0, macOS 26.0, *)
public func documentSemantics(from cgImage: CGImage, applyPostProcessing: Bool = true) async throws -> DocumentSemantics {
	let referenceSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
	let request = RecognizeDocumentsRequest()
	let observations = try await request.perform(on: cgImage, orientation: nil)
	
	guard let document = observations.first?.document else {
		throw DocumentScannerError.unrecognizedDocument
	}
	
	let extractor = DocumentBlockExtractor(image: cgImage, pageSize: referenceSize, allowStandaloneSupplementation: false)
	let (blocks, images) = try extractor.extractBlocksWithImages(from: document, applyPostProcessing: applyPostProcessing)
	let normalized = normalize(blocks: blocks, referenceSize: referenceSize)
	return DocumentSemantics(referenceSize: referenceSize, blocks: normalized, images: images)
}
#endif

private func normalize(blocks: [DocumentBlock], referenceSize: CGSize) -> [NormalizedDocumentBlock] {
	blocks.map { block in
		let normalizedBounds = block.bounds.normalized(in: referenceSize)
		
		switch block.kind {
		case .paragraph, .image:
			return NormalizedDocumentBlock(block: block, normalizedBounds: normalizedBounds)
		case .list(let list):
			let normalizedItems = list.items.map { item in
				NormalizedDocumentBlock.NormalizedListItem(
					normalizedBounds: item.bounds.normalized(in: referenceSize),
					item: item
				)
			}
			return NormalizedDocumentBlock(
				block: block,
				normalizedBounds: normalizedBounds,
				listItems: normalizedItems
			)
		case .table(let table):
			let normalizedRows: [[NormalizedDocumentBlock.NormalizedTableCell]] = table.rows.map { row in
				row.map { cell in
					NormalizedDocumentBlock.NormalizedTableCell(
						normalizedBounds: cell.bounds.normalized(in: referenceSize),
						cell: cell
					)
				}
			}
			return NormalizedDocumentBlock(
				block: block,
				normalizedBounds: normalizedBounds,
				tableRows: normalizedRows
			)
		}
	}
}
