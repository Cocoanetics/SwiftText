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

	var ink = pixels.map { $0 < 200 }

	for bounds in textBounds {
		let minX = max(0, Int((bounds.minX * scale).rounded(.down)))
		let maxX = min(width - 1, Int((bounds.maxX * scale).rounded(.up)))
		let minY = max(0, Int((bounds.minY * scale).rounded(.down)))
		let maxY = min(height - 1, Int((bounds.maxY * scale).rounded(.up)))
		guard minX <= maxX, minY <= maxY else { continue }
		for y in minY...maxY {
			for x in minX...maxX { ink[y * width + x] = false }
		}
	}

	let mask = dilate(ink, width: width, height: height, radius: 3)

	let pageArea = CGFloat(width * height)
	var visited = [Bool](repeating: false, count: width * height)
	var regions = [CGRect]()
	var stack = [Int]()

	for start in 0..<(width * height) where mask[start] && !visited[start] {
		var minX = width, minY = height, maxX = 0, maxY = 0
		visited[start] = true
		stack.append(start)
		while let index = stack.popLast() {
			let x = index % width, y = index / width
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

		// The dilation grew the box by its radius on every side.
		let box = CGRect(x: minX + 3, y: minY + 3, width: maxX - minX - 5, height: maxY - minY - 5)
		guard box.width > 0, box.height > 0 else { continue }
		// Specks, rules and residue of undetected text are not images.
		guard box.width * box.height >= pageArea * 0.01,
		      box.width >= CGFloat(width) * 0.04,
		      box.height >= CGFloat(height) * 0.04,
		      box.width < CGFloat(width) * 0.95 || box.height < CGFloat(height) * 0.95 else { continue }

		regions.append(CGRect(
			x: box.minX / scale, y: box.minY / scale, width: box.width / scale, height: box.height / scale
		).integral.intersection(CGRect(origin: .zero, size: pageSize)))
	}

	// A plot's curve can sit apart from its frame; the frame already covers it.
	return regions.filter { region in
		!regions.contains { $0 != region && $0.insetBy(dx: -2, dy: -2).contains(region) }
	}
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
