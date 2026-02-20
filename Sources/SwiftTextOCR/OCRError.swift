//
//  OCRError.swift
//  SwiftTextPDF
//
//  Created by Oliver Drobnik on 09.12.24.
//

import Foundation

/**
 Errors that can occur during OCR processing.
 */
@available(iOS 13.0, tvOS 13.0, macOS 10.15, visionOS 1.0, *)
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
				return "Failed to create CGContext for rendering."
			case .failedToCreateCGImage:
				return "Failed to create CGImage from the rendered CGContext."
			case .visionRequestFailed(let error):
				return "Vision request failed: \(error.localizedDescription)"
			case .noTextRecognized:
				return "No text could be recognized."
		}
	}
}



