//
//  VisualRegionDetection.swift
//  SwiftTextOCR
//

import CoreGraphics
import Foundation

/// Finds the separate non-text regions of a page — photos, thumbnails, line
/// charts, traces — by connected-component analysis of the non-white pixels.
///
/// Text is blanked out first, so only graphics remain. A small dilation joins
/// the strokes of one plot, while the white gutters between neighbouring photos
/// stay wider than the dilation and keep them apart.
///
/// - Parameters:
///   - cgImage: The rendered page.
///   - pageSize: The page size in pixels, matching the coordinates of `textBounds`.
///   - textBounds: Regions known to hold text, with the origin at the top-left.
/// - Returns: Bounding boxes in image space (origin at the top-left), in no particular order.
func detectVisualRegions(in cgImage: CGImage, pageSize: CGSize, excluding textBounds: [CGRect]) -> [CGRect] {
	let longestSide = max(pageSize.width, pageSize.height)
	guard longestSide > 0 else { return [] }

	// Analyse a downscaled copy; page-sized renders are far finer than the gutters need.
	let scale = min(1, 1000 / longestSide)
	let width = max(1, Int((pageSize.width * scale).rounded()))
	let height = max(1, Int((pageSize.height * scale).rounded()))

	var pixels = [UInt8](repeating: 255, count: width * height)
	let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
		guard let context = CGContext(
			data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
			bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
			bitmapInfo: CGImageAlphaInfo.none.rawValue
		) else { return false }
		context.interpolationQuality = .medium
		context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
		return true
	}
	guard drawn else { return [] }

	let textRanges = textBounds.compactMap { bounds -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? in
		let minX = max(0, Int((bounds.minX * scale).rounded(.down)))
		let maxX = min(width - 1, Int((bounds.maxX * scale).rounded(.up)))
		let minY = max(0, Int((bounds.minY * scale).rounded(.down)))
		let maxY = min(height - 1, Int((bounds.maxY * scale).rounded(.up)))
		guard minX <= maxX, minY <= maxY else { return nil }
		return (minX...maxX, minY...maxY)
	}

	let threshold = inkThreshold(pixels, width: width, textRanges: textRanges)
	var ink = pixels.map { $0 < threshold }

	for range in textRanges {
		for y in range.y {
			for x in range.x { ink[y * width + x] = false }
		}
	}

	let mask = dilate(ink, width: width, height: height, radius: 3)

	let pageArea = CGFloat(width * height)
	var visited = [Bool](repeating: false, count: width * height)
	var regions = [CGRect]()
	var stack = [Int]()

	for start in 0..<(width * height) where mask[start] && !visited[start] {
		var minX = width, minY = height, maxX = 0, maxY = 0
		var inkMinX = width, inkMinY = height, inkMaxX = 0, inkMaxY = 0
		var inkCount = 0
		visited[start] = true
		stack.append(start)
		while let index = stack.popLast() {
			let x = index % width, y = index / width
			if ink[index] {
				inkCount += 1
				inkMinX = min(inkMinX, x); inkMaxX = max(inkMaxX, x)
				inkMinY = min(inkMinY, y); inkMaxY = max(inkMaxY, y)
			}
			minX = min(minX, x); maxX = max(maxX, x)
			minY = min(minY, y); maxY = max(maxY, y)
			for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
				let nx = x + dx, ny = y + dy
				guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
				let neighbour = ny * width + nx
				if mask[neighbour] && !visited[neighbour] {
					visited[neighbour] = true
					stack.append(neighbour)
				}
			}
		}

		// The box covers the ink itself, not the margin the dilation grew around it.
		guard inkCount > 0 else { continue }
		let box = CGRect(x: inkMinX, y: inkMinY, width: inkMaxX - inkMinX + 1, height: inkMaxY - inkMinY + 1)
		// Specks, rules and residue of undetected text are not images.
		guard box.width * box.height >= pageArea * 0.01,
		      box.width >= CGFloat(width) * 0.04,
		      box.height >= CGFloat(height) * 0.04,
		      box.width < CGFloat(width) * 0.95 || box.height < CGFloat(height) * 0.95 else { continue }

		// A dark scan edge or page shadow is a thin strip lying along the border it
		// touches for most of the page, or an L around a corner that leaves most of
		// its box empty. A picture reaching the border, even a wide banner, stops
		// well short of running the page's whole length; line art reaching one edge
		// is sparse but does not wrap around a corner.
		let touchesVerticalBorder = minX == 0 || maxX == width - 1
		let touchesHorizontalBorder = minY == 0 || maxY == height - 1
		let verticalStrip = touchesVerticalBorder && box.height >= box.width * 5 && box.height >= CGFloat(height) * 0.75
		let horizontalStrip = touchesHorizontalBorder && box.width >= box.height * 5 && box.width >= CGFloat(width) * 0.75
		let cornerShadow = touchesVerticalBorder && touchesHorizontalBorder
			&& CGFloat(inkCount) < box.width * box.height * 0.5
		guard !verticalStrip, !horizontalStrip, !cornerShadow else { continue }

		regions.append(CGRect(
			x: box.minX / scale, y: box.minY / scale, width: box.width / scale, height: box.height / scale
		).integral.intersection(CGRect(origin: .zero, size: pageSize)))
	}

	// A plot's curve can sit apart from its frame; the frame already covers it.
	return regions.filter { region in
		!regions.contains { $0 != region && $0.insetBy(dx: -2, dy: -2).contains(region) }
	}
}

/// The luminance below which a pixel counts as ink.
///
/// Scans carry grey show-through from the back of the page that is darker than
/// white paper but much lighter than the printed ink. The paper level is the most
/// common bright luminance, and the text boxes show how dark the page's ink is;
/// anything lighter than 65% of the way from ink to paper is not ink. Without text
/// to calibrate on, only pixels clearly darker than the paper count.
///
/// Rendered pages and screenshots have pure white paper and no show-through, but
/// do have light fills and pale photo areas, so they keep the plain cut of 200.
private func inkThreshold(
	_ pixels: [UInt8], width: Int, textRanges: [(x: ClosedRange<Int>, y: ClosedRange<Int>)]
) -> UInt8 {
	var histogram = [Int](repeating: 0, count: 256)
	for pixel in pixels { histogram[Int(pixel)] += 1 }
	let paper = (128...255).max { histogram[$0] < histogram[$1] } ?? 255
	let fallback = min(200, paper - 40)
	guard paper < 250 else { return UInt8(fallback) }

	var textHistogram = [Int](repeating: 0, count: 256)
	var textInkCount = 0
	for range in textRanges {
		for y in range.y {
			for x in range.x {
				let pixel = Int(pixels[y * width + x])
				guard pixel < fallback else { continue }
				textHistogram[pixel] += 1
				textInkCount += 1
			}
		}
	}
	guard textInkCount > 0 else { return UInt8(fallback) }

	// The darker tail is the glyph cores; anti-aliased edges are lighter.
	var remaining = textInkCount / 10
	var textInk = 0
	while textInk < 255, remaining >= textHistogram[textInk] {
		remaining -= textHistogram[textInk]
		textInk += 1
	}
	return UInt8(min(fallback, textInk + (paper - textInk) * 65 / 100))
}

/// Square dilation with the given radius, done as two separable passes.
private func dilate(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
	var horizontal = [Bool](repeating: false, count: mask.count)
	for y in 0..<height {
		let rowStart = y * width
		for x in 0..<width {
			let lower = max(0, x - radius), upper = min(width - 1, x + radius)
			for nx in lower...upper where mask[rowStart + nx] { horizontal[rowStart + x] = true; break }
		}
	}

	var result = [Bool](repeating: false, count: mask.count)
	for x in 0..<width {
		for y in 0..<height {
			let lower = max(0, y - radius), upper = min(height - 1, y + radius)
			var hit = false
			for ny in lower...upper where horizontal[ny * width + x] { hit = true; break }
			result[y * width + x] = hit
		}
	}
	return result
}
