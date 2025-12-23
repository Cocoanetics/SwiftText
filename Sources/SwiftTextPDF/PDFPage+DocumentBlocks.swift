//
//  PDFPage+DocumentBlocks.swift
//  SwiftTextPDF
//
//  Created by OpenAI Codex on 11.12.24.
//

import Foundation
import PDFKit
import SwiftTextOCR
#if canImport(Vision)
import Vision
#endif

#if canImport(Vision)
extension PDFPage {
	public func documentBlocks(dpi: CGFloat = 300, applyPostProcessing: Bool = true) async throws -> [DocumentBlock] {
		return try await documentBlocksWithImages(dpi: dpi, applyPostProcessing: applyPostProcessing).blocks
	}

	public func documentBlocksWithImages(dpi: CGFloat = 300, applyPostProcessing: Bool = true) async throws -> (blocks: [DocumentBlock], images: [DocumentImage]) {
		guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else {
			throw DocumentScannerError.visionUnavailable
		}
		let (cgImage, _) = try renderedPageImage(dpi: dpi)
		let result = try await SwiftTextOCR.documentBlocks(from: cgImage, applyPostProcessing: applyPostProcessing)
		return result
	}

	/// Detects rectangular regions on the rendered page. Coordinates are returned in page space (origin at the top-left).
	public func detectedRectangles(dpi: CGFloat = 300) throws -> [CGRect] {
		guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else {
			throw DocumentScannerError.visionUnavailable
		}
		let (cgImage, _) = try renderedPageImage(dpi: dpi)
		return try SwiftTextOCR.detectedRectangles(from: cgImage)
	}
}
#else
extension PDFPage {
	public func documentBlocks(dpi: CGFloat = 300) async throws -> [DocumentBlock] {
		throw DocumentScannerError.visionUnavailable
	}
}
#endif
