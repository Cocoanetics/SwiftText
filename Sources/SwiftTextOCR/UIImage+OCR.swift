//
//  UIImage+OCR.swift
//  SwiftTextPDF
//
//  Created by Oliver Drobnik on 09.12.24.
//

#if canImport(UIKit)
import UIKit

public extension UIImage
{
	/**
	 Performs OCR (Optical Character Recognition) on the current image.
	 
	 - Returns: An array of `TextLine` objects representing the recognized text lines in the image.
	 - Throws: An `OCRError` if OCR processing or text recognition fails.
	 - Discussion:
	 This method forwards to the CGImage OCR implementation using the image's size and CGImage representation.
	 
	 - Note: This method requires iOS 13.0+, tvOS 13.0+, or macOS 10.15+. On earlier versions, this method will not be available.
	 */
	@available(iOS 13.0, tvOS 13.0, macOS 10.15, visionOS 1.0, *)
	func performOCR() throws -> [TextLine]?
	{
		guard let cgImage = self.cgImage else {
			throw OCRError.failedToCreateCGImage
		}
		return try cgImage.performOCR(imageSize: self.size)
	}
	
	/**
	 Extracts all text lines from the image as `TextLine` objects using OCR.
	 
	 - Returns: An array of `TextLine` objects representing recognized text lines from the image.
	 - Discussion:
	 This method performs OCR on the image to extract text. Since images don't have selectable text like PDFs, OCR is the only method available.
	 */
	@available(iOS 13.0, tvOS 13.0, macOS 10.15, visionOS 1.0, *)
	func textLines() -> [TextLine]
	{
		guard let cgImage = self.cgImage else { return [] }
		return cgImage.textLines(imageSize: self.size)
	}
	
	/**
	 Extracts all text from the image organized into lines, preserving logical line breaks.
	 
	 - Returns: An array of `String` objects, where each string represents a line of text extracted from the image.
	 */
	@available(iOS 13.0, tvOS 13.0, macOS 10.15, visionOS 1.0, *)
	var stringsFromLines: [String] {
		guard let cgImage = self.cgImage else { return [] }
		return cgImage.stringsFromLines(imageSize: self.size)
	}
	
	/**
	 Extracts all text from the image as a single string, preserving vertical spacing.
	 
	 - Returns: A `String` containing all extracted text from the image.
	 */
	@available(iOS 13.0, tvOS 13.0, macOS 10.15, visionOS 1.0, *)
	func extractText() -> String {
		guard let cgImage = self.cgImage else { return "" }
		return cgImage.extractText(imageSize: self.size)
	}
}
#endif

