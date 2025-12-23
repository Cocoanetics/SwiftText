//
//  PDFPage+DocumentSemantics.swift
//  SwiftTextPDF
//
//  Created by OpenAI Codex on 20.12.24.
//

import Foundation
import PDFKit
import SwiftTextOCR

#if canImport(Vision)
@available(iOS 26.0, tvOS 26.0, macOS 26.0, *)
extension PDFPage {
	public func documentSemantics(dpi: CGFloat = 300, applyPostProcessing: Bool = true) async throws -> DocumentSemantics {
		let (cgImage, _) = try renderedPageImage(dpi: dpi)
		return try await SwiftTextOCR.documentSemantics(from: cgImage, applyPostProcessing: applyPostProcessing)
	}
}
#endif
