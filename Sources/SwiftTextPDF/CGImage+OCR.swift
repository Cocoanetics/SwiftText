//
//  CGImage+OCR.swift
//  SwiftTextPDF
//
//  Created by Oliver Drobnik on 09.12.24.
//

import Foundation
#if canImport(Vision)
import Vision
#endif

public extension CGImage
{
	/**
	 Performs OCR (Optical Character Recognition) on the current image.
	 
	 - Parameter imageSize: The size of the image in points. Used to convert normalized Vision coordinates to image coordinates.
	 - Returns: An array of `TextLine` objects representing the recognized text lines in the image.
	 - Throws: An `OCRError` if OCR processing or text recognition fails.
	 - Discussion:
	 This method uses Apple's Vision framework to recognize text within the image. The recognized text is then organized into lines, preserving the relative positioning.
	 
	 The coordinate system uses normalized coordinates (0.0 to 1.0) from Vision, which are then converted to image coordinates based on the provided image size.
	 
	 - Note: This method requires iOS 13.0+, tvOS 13.0+, or macOS 10.15+. On earlier versions, this method will not be available.
	 
	 Example:
	 ```swift
	 do {
	 if let ocrLines = try cgImage.performOCR(imageSize: image.size) {
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
	func performOCR(imageSize: CGSize) throws -> [TextLine]?
	{
		#if canImport(Vision)
		// Perform text recognition using Vision
		let requestHandler = VNImageRequestHandler(cgImage: self, options: [:])
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
				let rect: CGRect
				if #available(iOS 18.0, tvOS 18.0, macOS 15.0, *) {
					let normalized = Vision.NormalizedRect(
						x: observation.boundingBox.minX,
						y: observation.boundingBox.minY,
						width: observation.boundingBox.width,
						height: observation.boundingBox.height
					)
					rect = normalized.toImageCoordinates(from: .fullImage, imageSize: imageSize, origin: .upperLeft)
				} else {
					let boundingBox = observation.boundingBox
					rect = CGRect(
						x: boundingBox.minX * imageSize.width,
						y: (1.0 - boundingBox.maxY) * imageSize.height,
						width: boundingBox.width  * imageSize.width,
						height: boundingBox.height * imageSize.height
					)
				}
				
				let fragment = TextFragment(bounds: rect, string: topCandidate.string)
				fragments.append(fragment)
			}
		}
		
		// Assemble fragments into lines
		return fragments.assembledLines()
		#else
		throw OCRError.noTextRecognized
		#endif
	}
	
	/**
	 Extracts all text lines from the image as `TextLine` objects using OCR.
	 
	 - Parameter imageSize: The size of the image in points.
	 - Returns: An array of `TextLine` objects representing recognized text lines from the image.
	 - Discussion:
	 This method performs OCR on the image to extract text. Since images don't have selectable text like PDFs, OCR is the only method available.
	 */
	@available(iOS 13.0, tvOS 13.0, macOS 10.15, *)
	func textLines(imageSize: CGSize) -> [TextLine]
	{
		return (try? performOCR(imageSize: imageSize)) ?? []
	}
	
	/**
	 Extracts all text from the image organized into lines, preserving logical line breaks.
	 
	 - Parameter imageSize: The size of the image in points.
	 - Returns: An array of `String` objects, where each string represents a line of text extracted from the image.
	 */
	@available(iOS 13.0, tvOS 13.0, macOS 10.15, *)
	func stringsFromLines(imageSize: CGSize) -> [String] {
		return textLines(imageSize: imageSize).map { $0.combinedText }
	}
	
	/**
	 Extracts all text from the image as a single string, preserving vertical spacing.
	 
	 - Parameter imageSize: The size of the image in points.
	 - Returns: A `String` containing all extracted text from the image.
	 */
	@available(iOS 13.0, tvOS 13.0, macOS 10.15, *)
	func extractText(imageSize: CGSize) -> String {
		return textLines(imageSize: imageSize).string()
	}
}
