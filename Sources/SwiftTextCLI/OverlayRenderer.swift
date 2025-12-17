//
//  OverlayRenderer.swift
//  SwiftTextCLI
//
//  Created by OpenAI Codex on 13.12.24.
//

import CoreGraphics
import Foundation
import ImageIO
import SwiftTextOCR
import UniformTypeIdentifiers

#if canImport(Vision)
@available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
enum OverlayRenderer {
	static func overlayImage(
		baseImage: CGImage,
		pageSize: CGSize,
		blocks: [DocumentBlock],
		lines: [TextLine],
		rectangles: [CGRect]
	) throws -> CGImage {
		let colorSpace = CGColorSpaceCreateDeviceRGB()
		guard let context = CGContext(
			data: nil,
			width: Int(pageSize.width),
			height: Int(pageSize.height),
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: colorSpace,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		) else {
			throw NSError(domain: "SwiftTextCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create overlay context"])
		}
		
			context.draw(baseImage, in: CGRect(origin: .zero, size: pageSize))

			context.saveGState()
			context.translateBy(x: 0, y: pageSize.height)
			context.scaleBy(x: 1, y: -1)

			drawLines(lines, on: context)
			drawBlocks(blocks, on: context)
			drawRectangles(rectangles, on: context)

			context.restoreGState()
		
		guard let cgImage = context.makeImage() else {
			throw NSError(domain: "SwiftTextCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to finalize overlay image"])
		}
		
		return cgImage
	}
	
	static func writeImage(_ image: CGImage, to url: URL, suggestedExtension: String) throws {
		let destinationType: UTType
		if let type = UTType(filenameExtension: suggestedExtension) {
			destinationType = type
		} else {
			destinationType = .png
		}
		
		guard let destination = CGImageDestinationCreateWithURL(url as CFURL, destinationType.identifier as CFString, 1, nil) else {
			throw NSError(domain: "SwiftTextCLI", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to create image destination at \(url.path)"])
		}
		CGImageDestinationAddImage(destination, image, nil)
		if !CGImageDestinationFinalize(destination) {
			throw NSError(domain: "SwiftTextCLI", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to save image at \(url.path)"])
		}
	}
	
	static func beginPDFContext(at url: URL) throws -> CGContext {
		guard let consumer = CGDataConsumer(url: url as CFURL) else {
			throw NSError(domain: "SwiftTextCLI", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unable to create PDF consumer at \(url.path)"])
		}
		guard let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
			throw NSError(domain: "SwiftTextCLI", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unable to create PDF context at \(url.path)"])
		}
		return context
	}
	
	static func drawPage(
		overlayImage: CGImage,
		into pdfContext: CGContext,
		mediaBox: CGRect
	) {
		var box = mediaBox
		pdfContext.beginPage(mediaBox: &box)
		pdfContext.draw(overlayImage, in: mediaBox)
		pdfContext.endPage()
	}
}

@available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
private extension OverlayRenderer {
	static func drawRectangles(_ rectangles: [CGRect], on context: CGContext) {
		guard !rectangles.isEmpty else { return }
		context.saveGState()
		context.setStrokeColor(CGColor(red: 0, green: 0.6, blue: 1, alpha: 0.7))
		context.setLineWidth(1.5)
		context.setLineDash(phase: 0, lengths: [6, 4])
		
		for rect in rectangles {
			context.stroke(rect)
		}
		context.restoreGState()
	}
	
	static func drawBlocks(_ blocks: [DocumentBlock], on context: CGContext) {
		for block in blocks {
			let color: CGColor
			switch block.kind {
			case .paragraph:
				color = CGColor(red: 1, green: 0, blue: 0, alpha: 0.8) // red
			case .list:
				color = CGColor(red: 1, green: 0.5, blue: 0, alpha: 0.8) // orange
			case .table:
				color = CGColor(red: 0.6, green: 0, blue: 0.8, alpha: 0.8) // purple
			case .image:
				color = CGColor(red: 1, green: 1, blue: 0, alpha: 0.8) // yellow
			}
			
			context.setStrokeColor(color)
			context.setLineWidth(2.5)
			
			let rect = block.bounds
			context.stroke(rect)
		}
	}
	
	static func drawLines(_ lines: [TextLine], on context: CGContext) {
		guard !lines.isEmpty else { return }
		context.saveGState()
		context.setStrokeColor(CGColor(red: 0, green: 1, blue: 0, alpha: 0.6))
		context.setLineWidth(1.5)
		
		for line in lines {
			let bounds = line.fragments.reduce(line.fragments.first?.bounds ?? .zero) { partial, fragment in
				partial.union(fragment.bounds)
			}
			context.stroke(bounds)
		}
		context.restoreGState()
	}
	
}
#endif
