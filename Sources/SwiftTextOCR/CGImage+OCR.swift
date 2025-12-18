//
//  CGImage+OCR.swift
//  SwiftTextOCR
//
//  Created by Oliver Drobnik on 09.12.24.
//

import Foundation
#if canImport(Vision)
import Vision
#endif

public extension CGImage
{
	/**
	 Performs OCR (Optical Character Recognition) on the current image.
	 
	 - Parameter imageSize: The size of the image in points. Used to convert normalized Vision coordinates to image coordinates.
	 - Returns: An array of `TextLine` objects representing the recognized text lines in the image.
	 - Throws: An `OCRError` if OCR processing or text recognition fails.
	 - Discussion:
	 This method uses Apple's Vision framework to recognize text within the image. The recognized text is then organized into lines, preserving the relative positioning.
	 
	 The coordinate system uses normalized coordinates (0.0 to 1.0) from Vision, which are then converted to image coordinates based on the provided image size.
	 
	 - Note: This method requires iOS 13.0+, tvOS 13.0+, or macOS 10.15+. On earlier versions, this method will not be available.
	 
	 Example:
	 ```swift
	 do {
	 if let ocrLines = try cgImage.performOCR(imageSize: image.size) {
	 for line in ocrLines {
	 print(line.combinedText)
	 }
	 }
	 } catch {
	 print("OCR failed: \(error)")
	 }
	 ```
	 */
	@available(iOS 13.0, tvOS 13.0, macOS 10.15, *)
	func performOCR(imageSize: CGSize) throws -> [TextLine]?
	{
		#if canImport(Vision)
		// Perform text recognition using Vision
		let requestHandler = VNImageRequestHandler(cgImage: self, options: [:])
		let textRecognitionRequest = VNRecognizeTextRequest()
		textRecognitionRequest.recognitionLevel = .accurate
		
		do {
			try requestHandler.perform([textRecognitionRequest])
		} catch {
			throw OCRError.visionRequestFailed(error)
		}
		
		// Process the Vision results
		guard let results = textRecognitionRequest.results else {
			throw OCRError.noTextRecognized
		}
		
		// Convert Vision results into TextFragments
		var fragments = [TextFragment]()
		for observation in results {
			if let topCandidate = observation.topCandidates(1).first {
				let rect: CGRect
				if #available(iOS 18.0, tvOS 18.0, macOS 15.0, *) {
					let normalized = Vision.NormalizedRect(
						x: observation.boundingBox.minX,
						y: observation.boundingBox.minY,
						width: observation.boundingBox.width,
						height: observation.boundingBox.height
					)
					rect = normalized.toImageCoordinates(from: .fullImage, imageSize: imageSize, origin: .upperLeft)
				} else {
					let boundingBox = observation.boundingBox
					rect = CGRect(
						x: boundingBox.minX * imageSize.width,
						y: (1.0 - boundingBox.maxY) * imageSize.height,
						width: boundingBox.width  * imageSize.width,
						height: boundingBox.height * imageSize.height
					)
				}
				
				let fragment = TextFragment(bounds: rect, string: topCandidate.string)
				fragments.append(fragment)
			}
		}
		
		let refinedFragments = refinedFragments(from: fragments, imageSize: imageSize)
		
		// Assemble fragments into lines
		return refinedFragments.assembledLines(splitVerticalFragments: true)
		#else
		throw OCRError.noTextRecognized
		#endif
	}
	
	/**
	 Extracts all text lines from the image as `TextLine` objects using OCR.
	 
	 - Parameter imageSize: The size of the image in points.
	 - Returns: An array of `TextLine` objects representing recognized text lines from the image.
	 - Discussion:
	 This method performs OCR on the image to extract text. Since images don't have selectable text like PDFs, OCR is the only method available.
	 */
	@available(iOS 13.0, tvOS 13.0, macOS 10.15, *)
	func textLines(imageSize: CGSize) -> [TextLine]
	{
		return (try? performOCR(imageSize: imageSize)) ?? []
	}
	
	/**
	 Extracts all text from the image organized into lines, preserving logical line breaks.
	 
	 - Parameter imageSize: The size of the image in points.
	 - Returns: An array of `String` objects, where each string represents a line of text extracted from the image.
	 */
	@available(iOS 13.0, tvOS 13.0, macOS 10.15, *)
	func stringsFromLines(imageSize: CGSize) -> [String] {
		return textLines(imageSize: imageSize).map { $0.combinedText }
	}
	
	/**
	 Extracts all text from the image as a single string, preserving vertical spacing.
	 
	 - Parameter imageSize: The size of the image in points.
	 - Returns: A `String` containing all extracted text from the image.
	 */
	@available(iOS 13.0, tvOS 13.0, macOS 10.15, *)
	func extractText(imageSize: CGSize) -> String {
		return textLines(imageSize: imageSize).string()
	}
}

private extension CGImage {
	func refinedFragments(from fragments: [TextFragment], imageSize: CGSize) -> [TextFragment] {
		guard !fragments.isEmpty, imageSize.width > 0, imageSize.height > 0 else { return fragments }
		let scaleX = CGFloat(width) / imageSize.width
		let scaleY = CGFloat(height) / imageSize.height
		guard scaleX.isFinite, scaleX > 0, scaleY.isFinite, scaleY > 0 else { return fragments }
		
		var refined = [TextFragment]()
		for fragment in fragments {
			if fragment.string.trimmingCharacters(in: .whitespacesAndNewlines).contains(" ") {
				let splits = splitFragmentByEstimatedWhitespace(fragment, scaleX: scaleX, scaleY: scaleY)
				refined.append(contentsOf: splits)
			} else {
				refined.append(fragment)
			}
		}
		return refined
	}
	
	func splitFragmentByEstimatedWhitespace(_ fragment: TextFragment, scaleX: CGFloat, scaleY: CGFloat) -> [TextFragment] {
		let pixelRectTopLeft = CGRect(
			x: fragment.bounds.minX * scaleX,
			y: fragment.bounds.minY * scaleY,
			width: fragment.bounds.width * scaleX,
			height: fragment.bounds.height * scaleY
		)
		
		let originX = max(0, min(pixelRectTopLeft.minX.rounded(.down), CGFloat(width - 1)))
		let originY = max(0, min(CGFloat(height) - (pixelRectTopLeft.maxY.rounded(.up)), CGFloat(height - 1)))
		let maxWidth = max(1, CGFloat(width) - originX)
		let maxHeight = max(1, CGFloat(height) - originY)
		let cropRect = CGRect(
			x: originX,
			y: originY,
			width: max(1, min(pixelRectTopLeft.width.rounded(.toNearestOrEven), maxWidth)),
			height: max(1, min(pixelRectTopLeft.height.rounded(.toNearestOrEven), maxHeight))
		)
		
		guard cropRect.width >= 4, cropRect.height >= 2,
			  let cropped = self.cropping(to: cropRect) else {
			return [fragment]
		}
		
		let gapColumns = horizontalWhitespaceColumns(in: cropped)
		guard !gapColumns.isEmpty else {
			return [fragment]
		}
		
		let tokens = fragment.string.split(whereSeparator: { $0.isWhitespace }).map(String.init)
		let requiredGaps = max(0, tokens.count - 1)
		guard requiredGaps > 0 else {
			return [fragment]
		}
		
		let gapMidpoints = gapColumns.map { range -> (range: ClosedRange<Int>, midpoint: CGFloat) in
			let mid = CGFloat(range.lowerBound + range.count / 2)
			return (range, mid)
		}
		
		guard gapMidpoints.count >= requiredGaps else {
#if DEBUG
			print("Skipping split for \"\(fragment.string)\" — tokens \(tokens.count) gaps \(gapMidpoints.count)")
#endif
			return [fragment]
		}
		
		let selectedTuples: [(range: ClosedRange<Int>, midpoint: CGFloat)]
		if gapMidpoints.count == requiredGaps {
			selectedTuples = gapMidpoints
		} else {
			selectedTuples = Array(
				gapMidpoints
					.sorted { lhs, rhs in
						let lhsWidth = lhs.range.count
						let rhsWidth = rhs.range.count
						if lhsWidth == rhsWidth {
							return lhs.range.lowerBound < rhs.range.lowerBound
						}
						return lhsWidth > rhsWidth
					}
					.prefix(requiredGaps)
			)
		}
		
		let sortedTuples = selectedTuples.sorted { $0.range.lowerBound < $1.range.lowerBound }
		let selectedMidpoints = sortedTuples.map(\.midpoint)
		
		let widthPixels = cropped.width
		let gapPositions = selectedMidpoints.map { midpoint -> CGFloat in
			let ratio = widthPixels > 0 ? midpoint / CGFloat(widthPixels) : 0
			return fragment.bounds.minX + ratio * fragment.bounds.width
		}.sorted()
		
		var xPositions: [CGFloat] = [fragment.bounds.minX]
		xPositions.append(contentsOf: gapPositions)
		xPositions.append(fragment.bounds.maxX)
		
		var result = [TextFragment]()
		for index in 0..<tokens.count {
			let minX = xPositions[index]
			let maxX = xPositions[index + 1]
			let bounds = CGRect(
				x: minX,
				y: fragment.bounds.minY,
				width: max(0.5, maxX - minX),
				height: fragment.bounds.height
			)
			let text = tokens[index].trimmingCharacters(in: .whitespacesAndNewlines)
			if !text.isEmpty {
				let newFragment = TextFragment(bounds: bounds, string: text)
				result.append(newFragment)
			}
		}
		
		if result.isEmpty {
			return [fragment]
		}
		
#if DEBUG
		print("Split OCR fragment \"\(fragment.string)\" into \(result.map(\.string))")
#endif
		
		return result
	}
	
	func horizontalWhitespaceColumns(in image: CGImage) -> [ClosedRange<Int>] {
		guard let provider = image.dataProvider,
			  let data = provider.data,
			  let ptr = CFDataGetBytePtr(data) else {
			return []
		}
		let width = image.width
		let height = image.height
		guard width > 0, height > 0 else { return [] }
		
		let bytesPerPixel = image.bitsPerPixel / 8
		let bytesPerRow = image.bytesPerRow
		guard bytesPerPixel >= 3 else { return [] }
		
		var columnInk = [CGFloat](repeating: 0, count: width)
		
		for x in 0..<width {
			var darkCount = 0
			for y in 0..<height {
				let offset = y * bytesPerRow + x * bytesPerPixel
				let r = CGFloat(ptr[offset])
				let g = CGFloat(ptr[offset + 1])
				let b = CGFloat(ptr[offset + 2])
				let luminance = 0.299 * r + 0.587 * g + 0.114 * b
				if luminance < 220 {
					darkCount += 1
				}
			}
			columnInk[x] = CGFloat(darkCount) / CGFloat(height)
		}
		
		let gapThreshold: CGFloat = 0.05
		let minGapColumns = max(1, width / 80)
		var gaps = [ClosedRange<Int>]()
		var currentStart: Int?
		
		for x in 0..<width {
			if columnInk[x] <= gapThreshold {
				if currentStart == nil {
					currentStart = x
				}
			} else if let start = currentStart {
				if x - start >= minGapColumns {
					gaps.append(start...(x - 1))
				}
				currentStart = nil
			}
		}
		
		if let start = currentStart, width - start >= minGapColumns {
			gaps.append(start...(width - 1))
		}
		
		return gaps
	}
}
