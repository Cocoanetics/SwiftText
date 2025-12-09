//
//  PDFDocument+Text.swift
//  SwiftTextPDF
//
//  Created by Oliver Drobnik on 29.11.24.
//

import PDFKit
#if canImport(Vision)
import Vision
#endif

public extension PDFDocument
{
	/**
	 Extracts all text lines from the PDF document as `TextLine` objects. Each `TextLine` represents a logical line of text, preserving vertical alignment and reading order.
	 
	 - Returns: An array of `TextLine` objects representing recognized text lines from the entire document.
	 - Discussion:
	   This method processes each page, first attempting to extract text using the PDFKit text selection mechanism. If no selectable text is found, it falls back to OCR using Apple's Vision framework.
	 */
	func textLines() -> [TextLine]
	{
		var allLines = [TextLine]()

		for pageIndex in 0..<self.pageCount
		{
			guard let page = self.page(at: pageIndex) else { continue }

			// Get the overall page bounds so we know its height
			let pageBounds = page.bounds(for: .mediaBox)
			let pageHeight = pageBounds.height

			let pageSelection = page.selection(for: pageBounds)
			
			// Attempt to extract text using PDFKit's selection mechanism
			if let selectionsByLine = pageSelection?.selectionsByLine(), !selectionsByLine.isEmpty
			{
				var fragments = [TextFragment]()
				for lineSelection in selectionsByLine
				{
					if let lineString = lineSelection.string
					{
						// Original PDFKit bounds (origin at bottom-left)
						let originalBounds = lineSelection.bounds(for: page)
						
						// Flip y so top = 0, bottom = pageHeight
						let flippedRect = CGRect(
							x: originalBounds.minX,
							y: pageHeight - originalBounds.maxY,
							width: originalBounds.width,
							height: originalBounds.height
						)
						
						let fragment = TextFragment(bounds: flippedRect, string: lineString)
						fragments.append(fragment)
					}
				}
				
				// Assemble fragments into logical lines
				allLines.append(contentsOf: fragments.assembledLines())
			}
			
			// Fallback to OCR if no text is available (iOS 13.0+, tvOS 13.0+, macOS 10.15+)
			else if #available(iOS 13.0, tvOS 13.0, macOS 10.15, *),
					let ocrTextLines = try? page.performOCR()
			{
				allLines.append(contentsOf: ocrTextLines)
			}
		}

		return allLines
	}

	/**
	 Extracts all text from the PDF document organized into lines, preserving logical line breaks.
	 
	 - Returns: An array of `String` objects, where each string represents a line of text extracted from the document.
	 - Discussion:
	   This computed property simply maps the `TextLine` objects returned by `textLines()` into their combined textual representation.
	 */
	var stringsFromLines: [String] {
		return textLines().map { $0.combinedText }
	}
	
	/**
	 Extracts all text from the PDF document as a single string, preserving vertical spacing and page breaks.
	 
	 - Returns: A `String` containing all extracted text from the document.
	 */
	func extractText() -> String {
		return textLines().string()
	}
}

