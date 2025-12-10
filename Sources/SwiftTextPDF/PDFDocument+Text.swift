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
			allLines.append(contentsOf: page.textLines())
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
	
	/**
	 Enumerates each page in the PDF document, extracting text lines and calling the provided closure.
	 
	 - Parameter body: A closure that receives the page and its extracted text lines. The closure can return `false` to stop enumeration.
	 - Discussion:
	 This method processes each page sequentially, first attempting to extract text using PDFKit's text selection mechanism. If no selectable text is found, it falls back to OCR using Apple's Vision framework.
	 
	 Example:
	 ```swift
	 pdfDocument.enumeratePages { page, textLines in
	 print("Page text: \(textLines.map { $0.combinedText }.joined(separator: "\n"))")
	 return true // Continue to next page
	 }
	 ```
	 */
	func enumeratePages(_ body: (PDFPage, [TextLine]) -> Bool)
	{
		for pageIndex in 0..<self.pageCount
		{
			guard let page = self.page(at: pageIndex) else { continue }
			
			let textLines = page.textLines()
			
			if !body(page, textLines) {
				break
			}
		}
	}
}

