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

	@Test("Scan edge shadow and grey show-through on a scanned page are not images")
	func ignoresScanArtefacts() throws {
		let page = try ScannedPage.render()
		let regions = detectVisualRegions(in: page.image, pageSize: ScannedPage.size, excluding: page.textBounds)
		#expect(regions.isEmpty, "\(regions)")
	}

	@Test("A photo in the body of a noisy scanned page is still found", arguments: [
		CGRect(x: 700, y: 1300, width: 1100, height: 700),
		// Close to the right edge, but not touching it.
		CGRect(x: 1800, y: 1300, width: 720, height: 700),
		// A 6:1 banner running into the bottom edge.
		CGRect(x: 700, y: 3050, width: 1500, height: 250)
	])
	func findsPhotoOnScannedPage(photo: CGRect) throws {
		let page = try ScannedPage.render(photo: photo)
		let regions = detectVisualRegions(in: page.image, pageSize: ScannedPage.size, excluding: page.textBounds)
		#expect(regions.count == 1, "\(regions)")
		let region = try #require(regions.first)
		#expect(region.insetBy(dx: -8, dy: -8).contains(photo), "\(region)")
		#expect(photo.insetBy(dx: -8, dy: -8).contains(region), "\(region)")
	}
}

/// A synthetic 300 dpi greyscale book scan: lines of text, a footnote under a
/// rule, mirrored grey show-through from the back of the leaf in the margins and
/// between the lines, and a dark shadow along the left and top edges.
private enum ScannedPage {
	static let size = CGSize(width: 2550, height: 3300)

	/// Rects use a top-left origin, like the text boxes Vision reports.
	static func render(photo: CGRect? = nil) throws -> (image: CGImage, textBounds: [CGRect]) {
		let context = try #require(CGContext(
			data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
			bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
			bitmapInfo: CGImageAlphaInfo.none.rawValue
		))
		func fill(_ rect: CGRect, gray: CGFloat) {
			context.setFillColor(CGColor(gray: gray, alpha: 1))
			context.fill(CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height))
		}
		var seed: UInt32 = 268
		func random(_ range: ClosedRange<Int>) -> CGFloat {
			seed = seed &* 1_664_525 &+ 1_013_904_223
			return CGFloat(range.lowerBound + Int(seed >> 16) % (range.count))
		}

		// Slightly grey paper.
		fill(CGRect(origin: .zero, size: size), gray: 0.95)

		// Show-through: the back page's denser lines, mirrored so they spill into the
		// left margin and show between this side's lines, as soft grey word smudges.
		var y: CGFloat = 230
		while y < 3150 {
			var x: CGFloat = 120
			while x < 2150 {
				let word = random(60...220)
				fill(CGRect(x: x, y: y, width: min(word, 2150 - x), height: 30), gray: 0.66)
				x += word + random(18...30)
			}
			y += 44
		}

		// Shadow where the page curved away from the scanner glass: a gradient
		// down the left edge and across the top of the left part of the page.
		let shadow = try #require(CGGradient(
			colorsSpace: CGColorSpaceCreateDeviceGray(),
			colors: [CGColor(gray: 0.15, alpha: 1), CGColor(gray: 0.95, alpha: 1)] as CFArray,
			locations: [0, 1]
		))
		context.saveGState()
		context.clip(to: CGRect(x: 0, y: 0, width: 280, height: size.height))
		context.drawLinearGradient(shadow, start: .zero, end: CGPoint(x: 280, y: 0), options: [])
		context.restoreGState()
		context.saveGState()
		context.clip(to: CGRect(x: 0, y: size.height - 200, width: 1700, height: 200))
		context.drawLinearGradient(
			shadow, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: size.height - 200), options: []
		)
		context.restoreGState()

		// Body text and the footnote, as word-shaped runs of dark glyph stems.
		var textBounds = [CGRect]()
		func line(top: CGFloat, xHeight: CGFloat, stem: CGFloat, width lineWidth: CGFloat) {
			let left: CGFloat = 300
			var x = left
			while x < left + lineWidth - 40 {
				let letters = Int(random(2...9))
				for _ in 0..<letters {
					let ascender = random(0...3) == 0 ? xHeight * 0.4 : 0
					fill(CGRect(x: x, y: top - ascender, width: stem, height: xHeight + ascender), gray: 0.08)
					x += stem * 2.6
				}
				x += stem * 4
			}
			textBounds.append(CGRect(x: left - 6, y: top - xHeight * 0.4 - 6, width: x - left + 12, height: xHeight * 1.4 + 12))
		}

		var top: CGFloat = 300
		while top < 2700 {
			if let photo, top + 50 > photo.minY - 40, top < photo.maxY + 40 {
				top += 80
				continue
			}
			line(top: top, xHeight: 30, stem: 7, width: top > 2600 ? 900 : 1950)
			top += 80
		}

		// Footnote rule and small-type footnote lines.
		fill(CGRect(x: 300, y: 2800, width: 600, height: 4), gray: 0.08)
		for index in 0..<4 {
			line(top: 2850 + CGFloat(index) * 44, xHeight: 20, stem: 5, width: index == 3 ? 700 : 1950)
		}

		if let photo {
			// A dark photo with a lighter sky above a darker ground.
			fill(photo, gray: 0.5)
			fill(CGRect(x: photo.minX, y: photo.midY, width: photo.width, height: photo.height / 2), gray: 0.25)
		}

		return (try #require(context.makeImage()), textBounds)
	}
}
