//
//  VisualRegionDetectionTests.swift
//  SwiftTextOCRTests
//

import CoreGraphics
import Foundation
import Testing

@testable import SwiftTextOCR

struct VisualRegionDetectionTests {
	private let pageSize = CGSize(width: 1200, height: 1600)

	private func renderPage(_ draw: (CGContext) -> Void) throws -> CGImage {
		let context = try #require(CGContext(
			data: nil, width: Int(pageSize.width), height: Int(pageSize.height), bitsPerComponent: 8,
			bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		))
		context.setFillColor(CGColor(gray: 1, alpha: 1))
		context.fill(CGRect(origin: .zero, size: pageSize))
		draw(context)
		return try #require(context.makeImage())
	}

	@Test("Framed photos side by side and a line chart become separate regions")
	func separatesPhotosAndFindsChart() throws {
		// Rects below use a top-left origin; flip into CoreGraphics space to draw.
		func flipped(_ rect: CGRect) -> CGRect {
			CGRect(x: rect.minX, y: pageSize.height - rect.maxY, width: rect.width, height: rect.height)
		}
		let photos = (0..<4).map { CGRect(x: 60 + CGFloat($0) * 280, y: 100, width: 260, height: 170) }
		let chart = CGRect(x: 100, y: 500, width: 1000, height: 500)

		let image = try renderPage { context in
			for (index, photo) in photos.enumerated() {
				context.setFillColor(CGColor(gray: 0.35 + CGFloat(index) * 0.05, alpha: 1))
				context.fill(flipped(photo))
			}
			context.setStrokeColor(CGColor(gray: 0, alpha: 1))
			context.setLineWidth(3)
			context.stroke(flipped(chart))
			context.beginPath()
			context.move(to: CGPoint(x: chart.minX + 20, y: pageSize.height - (chart.maxY - 30)))
			context.addLine(to: CGPoint(x: chart.midX, y: pageSize.height - (chart.minY + 80)))
			context.addLine(to: CGPoint(x: chart.maxX - 20, y: pageSize.height - (chart.minY + 200)))
			context.strokePath()
		}

		let regions = detectVisualRegions(in: image, pageSize: pageSize, excluding: [])
		#expect(regions.count == 5, "\(regions)")

		for photo in photos {
			let matches = regions.filter { $0.intersection(photo).width * $0.intersection(photo).height > photo.width * photo.height * 0.9 }
			#expect(matches.count == 1)
			#expect(matches.first.map { $0.width < photo.width + 20 && $0.height < photo.height + 20 } == true)
		}
		let chartMatches = regions.filter { $0.width > 900 && $0.height > 400 }
		#expect(chartMatches.count == 1)
	}

	@Test("Regions marked as text are not reported")
	func skipsTextRegions() throws {
		let block = CGRect(x: 100, y: 100, width: 600, height: 300)
		let image = try renderPage { context in
			context.setFillColor(CGColor(gray: 0, alpha: 1))
			context.fill(CGRect(x: block.minX, y: pageSize.height - block.maxY, width: block.width, height: block.height))
		}
		#expect(detectVisualRegions(in: image, pageSize: pageSize, excluding: [block.insetBy(dx: -5, dy: -5)]).isEmpty)
		#expect(detectVisualRegions(in: image, pageSize: pageSize, excluding: []).count == 1)
	}
}
