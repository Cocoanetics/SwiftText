//
//  PDFPage+OCR.swift
//  SwiftTextPDF
//
//  Created by Oliver Drobnik on 05.12.24.
//

import Foundation
import PDFKit
#if canImport(Vision)
import Vision
#endif

extension PDFPage
{
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
	@available(iOS 13.0, tvOS 13.0, macOS 10.15, *)
	public func performOCR() throws -> [TextLine]?
	{
		// Define the desired resolution (e.g., 300 DPI)
		let dpi: CGFloat = 300
		let pageBounds = self.bounds(for: .mediaBox)
		let scale = dpi / 72.0 // PDF default resolution is 72 DPI
		let targetSize = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
		
		// Create a bitmap context with the desired resolution
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
		
		// Set the context's coordinate system to match the PDF's coordinate system
		context.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0) // White background
		context.fill(CGRect(origin: .zero, size: targetSize))
		context.scaleBy(x: scale, y: scale)
		
		// Render the PDF page into the context
		draw(with: .mediaBox, to: context)
		
		// Create a CGImage from the context
		guard let cgImage = context.makeImage() else {
			throw OCRError.failedToCreateCGImage
		}
		
		// Use CGImage OCR functionality
		return try cgImage.performOCR(imageSize: pageBounds.size)
	}
}

