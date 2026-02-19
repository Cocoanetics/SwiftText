//
//  PDFPage+OCR.swift
//  SwiftTextPDF
//
//  Created by Oliver Drobnik on 05.12.24.
//

import Foundation
import ImageIO
import PDFKit
import SwiftTextOCR
#if canImport(Vision)
import Vision
#endif

extension PDFPage
{
	/// Renders the PDF page into a bitmap image at the specified DPI and returns the created CGImage with the page's logical size.
	@available(iOS 13.0, tvOS 13.0, macOS 10.15, visionOS 1.0, *)
	public func renderedPageImage(dpi: CGFloat = 300) throws -> (CGImage, CGSize)
	{
		let pageBounds = self.bounds(for: .mediaBox)
		let scale = dpi / 72.0 // PDF default resolution is 72 DPI
		let targetSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
		
		let colorSpace = CGColorSpaceCreateDeviceRGB()
		guard let context = CGContext(
			data: nil,
			width: Int(targetSize.width),
			height: Int(targetSize.height),
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: colorSpace,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		) else {
			throw OCRError.failedToCreateContext
		}
		
		context.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
		context.fill(CGRect(origin: .zero, size: targetSize))
		context.scaleBy(x: scale, y: scale)
		draw(with: .mediaBox, to: context)
		
		guard let cgImage = context.makeImage() else {
			throw OCRError.failedToCreateCGImage
		}
		
		return (cgImage, targetSize)
	}
	
	/**
	 Extracts all text lines from the PDF page as `TextLine` objects. Each `TextLine` represents a logical line of text, preserving vertical alignment and reading order.
	 
	 - Returns: An array of `TextLine` objects representing recognized text lines from the page.
	 - Discussion:
	   This method first attempts to extract text using the PDFKit text selection mechanism. If no selectable text is found, it falls back to OCR using Apple's Vision framework.
	 */
	public func textLines() -> [TextLine]
	{
		if let selectionLines = textLinesFromSelections(), !selectionLines.isEmpty
		{
			return selectionLines
		}
		
		if let ocrLines = textLinesFromOCR()
		{
			return ocrLines
		}
		
		return []
	}
	
	public func textLinesFromSelections() -> [TextLine]?
	{
		let pageBounds = bounds(for: .mediaBox)
		let pageHeight = pageBounds.height
		guard let pageSelection = selection(for: pageBounds) else {
			return nil
		}
		
		let selectionsByLine = pageSelection.selectionsByLine()
		guard !selectionsByLine.isEmpty else { return nil }
		
		var fragments = [TextFragment]()
		
		for lineSelection in selectionsByLine
		{
			fragments.append(contentsOf: selectionFragments(from: lineSelection, pageHeight: pageHeight))
		}
		
		return fragments.isEmpty ? nil : fragments.assembledLines(splitVerticalFragments: true)
	}
	
	func textLinesFromOCR() -> [TextLine]?
	{
		if #available(iOS 13.0, tvOS 13.0, macOS 10.15, visionOS 1.0, *),
		   let textLines = try? performOCR()
		{
			return textLines
		}
		
		return nil
	}
	
	/**
	 Performs OCR (Optical Character Recognition) on the current PDF page.
	 
	 - Returns: An array of `TextLine` objects representing the recognized text lines on the page.
	 - Throws: An `OCRError` if rendering, OCR processing, or text recognition fails.
	 - Discussion:
	 This method renders the PDF page at a high resolution (300 DPI) and uses Apple's Vision framework to recognize text within the rendered image. The recognized text is then organized into lines, preserving the relative positioning.
	 
	 The coordinate system is adjusted to match the PDF's coordinate system, ensuring accurate mapping of recognized text to the PDF page.
	 
	 - Note: This method requires iOS 13.0+, tvOS 13.0+, or macOS 10.15+. On earlier versions, this method will not be available.
	 
	 Example:
	 ```swift
	 do {
	 if let ocrLines = try page.performOCR() {
	 for line in ocrLines {
	 print(line.combinedText)
	 }
	 }
	 } catch {
	 print("OCR failed: \(error)")
	 }
	 ```
	 */
	@available(iOS 13.0, tvOS 13.0, macOS 10.15, visionOS 1.0, *)
	public func performOCR() throws -> [TextLine]?
	{
		let pageBounds = self.bounds(for: .mediaBox)
		let (cgImage, _) = try renderedPageImage()
		return try cgImage.performOCR(imageSize: pageBounds.size)
	}
	
	private func selectionFragments(from lineSelection: PDFSelection, pageHeight: CGFloat) -> [TextFragment]
	{
		guard let pageString = string, !pageString.isEmpty else {
			return fragmentsFromFallbackSelection(lineSelection, pageHeight: pageHeight)
		}
		
		let nsString = pageString as NSString
		let rangeCount = lineSelection.numberOfTextRanges(on: self)
		guard rangeCount > 0 else {
			return fragmentsFromFallbackSelection(lineSelection, pageHeight: pageHeight)
		}
		
#if DEBUG
		if let lineText = lineSelection.string {
			let debugTargets = ["CRV*BILLA DANKT 000344"]
			if debugTargets.contains(where: { lineText.contains($0) }) {
				let pageSize = bounds(for: .mediaBox).size
				logCharacterBounds(for: lineSelection, sourceString: nsString, pageSize: pageSize)
				print("Line selection \"\(lineText.trimmingCharacters(in: .whitespacesAndNewlines))\" uses \(rangeCount) ranges")
				for rangeIndex in 0..<rangeCount {
					let nsRange = lineSelection.range(at: rangeIndex, on: self)
					let snippet = nsString.substring(with: nsRange)
					let rect = lineSelection.bounds(for: self)
					print("  range[\(rangeIndex)] \(nsRange) snippet: \(snippet)")
					print("    bounds: \(rect)")
				}
			}
		}
#endif
		
		let lineBounds = flippedRect(from: lineSelection.bounds(for: self), pageHeight: pageHeight)
		var fragments = [TextFragment]()
		
		for rangeIndex in 0..<rangeCount {
			let nsRange = lineSelection.range(at: rangeIndex, on: self)
			fragments.append(
				contentsOf: selectionFragments(
					in: nsRange,
					from: nsString,
					pageHeight: pageHeight,
					lineBounds: lineBounds
				)
			)
		}
		
		if fragments.isEmpty {
			return fragmentsFromFallbackSelection(lineSelection, pageHeight: pageHeight)
		}
		
		return fragments
	}
	
	private func selectionFragments(
		in range: NSRange,
		from sourceString: NSString,
		pageHeight: CGFloat,
		lineBounds: CGRect
	) -> [TextFragment] {
		guard range.length > 0 else { return [] }
		
		var result = [TextFragment]()
		let upperBound = range.location + range.length
		var currentStart: Int?
		var currentLength = 0
		var currentBounds = CGRect.null
		var previousCharacterBounds: CGRect?
		var hadWhitespaceGap = false
		
		func flushCurrent() {
			guard let start = currentStart, currentLength > 0 else { return }
			let fragmentRange = NSRange(location: start, length: currentLength)
			let rawText = sourceString.substring(with: fragmentRange)
			let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else {
				currentStart = nil
				currentLength = 0
				currentBounds = .null
				return
			}
			
			guard !currentBounds.isNull else {
				currentStart = nil
				currentLength = 0
				currentBounds = .null
				return
			}
			
			let flipped = flippedRect(from: currentBounds, pageHeight: pageHeight)
			let aligned = alignedRect(flipped, to: lineBounds)
			result.append(TextFragment(bounds: aligned, string: trimmed))
			currentStart = nil
			currentLength = 0
			currentBounds = .null
		}
		
		var index = range.location
		while index < upperBound {
			let charCode = sourceString.character(at: index)
			let scalar = UnicodeScalar(charCode)
			let isWhitespace = scalar.map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
			
			if currentStart == nil {
				if isWhitespace {
					index += 1
					continue
				}
				currentStart = index
				currentBounds = .null
				currentLength = 0
			}
			
			let bounds = resolvedBoundsForCharacter(at: index)
			let hasBounds = !(bounds.isNull || bounds.isEmpty)
			
			if !isWhitespace, hasBounds {
				if let previous = previousCharacterBounds,
				   hadWhitespaceGap,
				   shouldSplit(after: previous, before: bounds)
				{
					flushCurrent()
					previousCharacterBounds = nil
					hadWhitespaceGap = false
					currentStart = index
					currentBounds = .null
					currentLength = 0
				}
				
				hadWhitespaceGap = false
				currentBounds = currentBounds.isNull ? bounds : currentBounds.union(bounds)
				previousCharacterBounds = bounds
			}
			else if isWhitespace {
				hadWhitespaceGap = true
			}
			
			currentLength += 1
			index += 1
		}
		
		flushCurrent()
		return result
	}
	
	private func fragmentsFromFallbackSelection(_ selection: PDFSelection, pageHeight: CGFloat) -> [TextFragment]
	{
		guard
			let rawString = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
			!rawString.isEmpty
		else {
			return []
		}
		
		let bounds = flippedRect(from: selection.bounds(for: self), pageHeight: pageHeight)
		return [TextFragment(bounds: bounds, string: rawString)]
	}
	
	private func flippedRect(from rect: CGRect, pageHeight: CGFloat) -> CGRect
	{
		return CGRect(
			x: rect.minX,
			y: pageHeight - rect.maxY,
			width: rect.width,
			height: rect.height
		)
	}
	
	private func shouldSplit(after previous: CGRect, before current: CGRect) -> Bool
	{
		let medianHeight = max((previous.height + current.height) / 2.0, 1)
		let widthLimit = max(medianHeight * 3, 12)
		let effectivePreviousWidth = min(previous.width, widthLimit)
		let effectiveCurrentWidth = min(current.width, widthLimit)
		let medianWidth = max((effectivePreviousWidth + effectiveCurrentWidth) / 2.0, 1)
		let gapThreshold = max(medianWidth * 1.5, medianHeight * 0.6, 4)
		
		let adjustedPreviousMaxX = previous.minX + effectivePreviousWidth
		let gap = current.minX - adjustedPreviousMaxX
		return gap > gapThreshold
	}
	
	private func resolvedBoundsForCharacter(at index: Int) -> CGRect
	{
		guard index >= 0 else { return .null }
		let range = NSRange(location: index, length: 1)
		if let selection = selection(for: range) {
			let bounds = selection.bounds(for: self)
			if !bounds.isNull && !bounds.isEmpty {
				return bounds
			}
		}
		return characterBounds(at: index)
	}
	
	private func alignedRect(_ rect: CGRect, to lineBounds: CGRect) -> CGRect
	{
		let deltaY = lineBounds.midY - rect.midY
		return CGRect(
			x: rect.minX,
			y: rect.minY + deltaY,
			width: rect.width,
			height: rect.height
		)
	}
#if DEBUG
	private func logCharacterBounds(for selection: PDFSelection, sourceString: NSString, pageSize: CGSize)
	{
		guard pageSize.width > 0, pageSize.height > 0 else { return }
		print("Character bounds for selection: \(selection.string ?? "")")
		let rangeCount = selection.numberOfTextRanges(on: self)
		for rangeIndex in 0..<rangeCount {
			let nsRange = selection.range(at: rangeIndex, on: self)
			for offset in 0..<nsRange.length {
				let globalIndex = nsRange.location + offset
				let character = sourceString.character(at: globalIndex)
				let scalar = UnicodeScalar(character).map(String.init) ?? "?"
				let rect = resolvedBoundsForCharacter(at: globalIndex)
				let normalized = NormalizedRect(
					minX: rect.minX / pageSize.width,
					minY: rect.minY / pageSize.height,
					width: rect.width / pageSize.width,
					height: rect.height / pageSize.height
				)
				print("  char[\(globalIndex)] \(scalar) (\(character)) bounds: \(rect) normalized: \(normalized)")
			}
		}
	}
#endif
}
