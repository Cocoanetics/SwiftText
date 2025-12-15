//
//  DocumentImage.swift
//  SwiftTextPDF
//
//  Created by OpenAI Codex on 12.12.24.
//

import CoreGraphics
import Foundation

/// Represents an image detected within a document along with its bounds.
public struct DocumentImage {
	public let bounds: CGRect
	public let image: CGImage
}
