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
	 Errors that can occur during OCR processing on a PDF page.
	 */
	@available(iOS 13.0, tvOS 13.0, macOS 10.15, *)
	public enum OCRError: Error, CustomStringConvertible
	{
		case failedToCreateContext
		case failedToCreateCGImage
		case visionRequestFailed(Error)
		case noTextRecognized
		
		public var description: String
		{
			switch self
			{
				case .failedToCreateContext:
					return "Failed to create CGContext for rendering the PDF page."
				case .failedToCreateCGImage:
					return "Failed to create CGImage from the rendered CGContext."
				case .visionRequestFailed(let error):
					return "Vision request failed: \(error.localizedDescription)"
				case .noTextRecognized:
					return "No text could be recognized on the page."
			}
		}
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
		context.setFillColor(CGColor.white) // White background
		context.fill(CGRect(origin: .zero, size: targetSize))
		context.scaleBy(x: scale, y: scale)
		
		// Render the PDF page into the context
		draw(with: .mediaBox, to: context)
		
		// Create a CGImage from the context
		guard let cgImage = context.makeImage() else {
			throw OCRError.failedToCreateCGImage
		}
		
		// Perform text recognition using Vision
		let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
		let textRecognitionRequest = VNRecognizeTextRequest()
		textRecognitionRequest.recognitionLevel = .accurate
		
		do {
			try requestHandler.perform([textRecognitionRequest])
		} catch {
			throw OCRError.visionRequestFailed(error)
		}
		
		// Process the Vision results
		guard let results = textRecognitionRequest.results else {
			throw OCRError.noTextRecognized
		}
		
		// Convert Vision results into TextFragments
		var fragments = [TextFragment]()
		for observation in results {
			if let topCandidate = observation.topCandidates(1).first {
				let boundingBox = observation.boundingBox
				
				let bounds = CGRect(
					x: boundingBox.minX * pageBounds.width,
					y: (1.0 - boundingBox.maxY) * pageBounds.height, // flipped y
					width: boundingBox.width  * pageBounds.width,
					height: boundingBox.height * pageBounds.height
				)
				
				let fragment = TextFragment(bounds: bounds, string: topCandidate.string)
				fragments.append(fragment)
			}
		}
		
		// Assemble fragments into lines and reverse for correct order (PDF uses bottom-to-top coordinates)
		return fragments.assembledLines()
	}
}

