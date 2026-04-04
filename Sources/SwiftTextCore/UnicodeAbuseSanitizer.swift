import Foundation

public struct UnicodeAbuseReport: Equatable, Sendable {
	public var maxClusterSize: Int = 0
	public var excessiveCombiningMarks: Int = 0
	public var zwjChainLength: Int = 0
	public var hasBidiOverrides = false
	public var hasTagAbuse = false

	public var containsAbuse: Bool {
		maxClusterSize > UnicodeAbuseSanitizer.maximumSafeClusterScalars
			|| excessiveCombiningMarks > 0
			|| zwjChainLength > UnicodeAbuseSanitizer.maximumSafeZWJSequenceScalars
			|| hasBidiOverrides
			|| hasTagAbuse
	}
}

public struct UnicodeSanitizationResult: Equatable, Sendable {
	public let text: String
	public let report: UnicodeAbuseReport
}

public enum UnicodeAbuseSanitizer {
	private static let zeroWidthJoiner = UnicodeScalar(0x200D)!
	private static let blackFlag = UnicodeScalar(0x1F3F4)!
	private static let cancelTag = UnicodeScalar(0xE007F)!

	static let maximumSafeClusterScalars = 50
	static let maximumSafeOutputClusterScalars = 16
	static let maximumAllowedCombiningMarks = 15
	static let combiningMarkWarningThreshold = 5
	static let maximumSafeZWJSequenceScalars = 11
	static let maximumAllowedVariationSelectors = 1
	static let maximumAllowedTagScalars = 8

	public static func sanitize(_ text: String) -> UnicodeSanitizationResult {
		guard !text.isEmpty else {
			return UnicodeSanitizationResult(text: text, report: UnicodeAbuseReport())
		}

		var report = UnicodeAbuseReport()
		var sanitized = String.UnicodeScalarView()

		for character in text {
			let scalars = Array(String(character).unicodeScalars)
			report.maxClusterSize = max(report.maxClusterSize, scalars.count)
			report.zwjChainLength = max(report.zwjChainLength, zwjChainLength(in: scalars))

			let sanitizedCluster = sanitizeCluster(scalars, report: &report)
			sanitized.append(contentsOf: sanitizedCluster)
		}

		let normalized = String(sanitized).precomposedStringWithCanonicalMapping
		return UnicodeSanitizationResult(text: normalized, report: report)
	}

	private static func sanitizeCluster(_ scalars: [UnicodeScalar], report: inout UnicodeAbuseReport) -> [UnicodeScalar] {
		guard !scalars.isEmpty else { return [] }

		let keptTagIndices = validTagIndices(in: scalars)
		var result: [UnicodeScalar] = []
		var combiningCount = 0
		var variationSelectorCount = 0
		var hasTrimmedCombiningMarks = false
		var nonZWJScalarCount = 0

		for (index, scalar) in scalars.enumerated() {
			if isBidiOverride(scalar) {
				report.hasBidiOverrides = true
				continue
			}

			if isTagScalar(scalar) {
				if keptTagIndices.contains(index) {
					result.append(scalar)
				} else {
					report.hasTagAbuse = true
				}
				continue
			}

			if isVariationSelector(scalar) {
				if variationSelectorCount < maximumAllowedVariationSelectors {
					result.append(scalar)
					variationSelectorCount += 1
				}
				continue
			}

			if isCombiningMark(scalar) {
				combiningCount += 1
				if combiningCount <= maximumAllowedCombiningMarks {
					result.append(scalar)
				} else {
					hasTrimmedCombiningMarks = true
				}
				continue
			}

			result.append(scalar)
			if scalar != "\u{200D}" {
				nonZWJScalarCount += 1
			}

			if scalar == zeroWidthJoiner, nonZWJScalarCount >= maximumSafeZWJSequenceScalars {
				report.zwjChainLength = max(report.zwjChainLength, max(scalars.count, maximumSafeZWJSequenceScalars + 1))
				break
			}
		}

		if combiningCount > combiningMarkWarningThreshold {
			report.excessiveCombiningMarks += 1
		}

		if hasTrimmedCombiningMarks {
			report.excessiveCombiningMarks += 1
		}

		if result.count > maximumSafeOutputClusterScalars {
			result = Array(result.prefix(maximumSafeOutputClusterScalars))
		}

		return result
	}

	private static func zwjChainLength(in scalars: [UnicodeScalar]) -> Int {
		guard scalars.contains(zeroWidthJoiner) else {
			return 0
		}
		return scalars.count
	}

	private static func validTagIndices(in scalars: [UnicodeScalar]) -> Set<Int> {
		let tagIndices = scalars.indices.filter { isTagScalar(scalars[$0]) }
		guard !tagIndices.isEmpty else { return [] }

		guard scalars.first == blackFlag else {
			return []
		}

		guard let lastTagIndex = tagIndices.last, scalars[lastTagIndex] == cancelTag else {
			return []
		}

		let nonCancelTagCount = tagIndices.count - 1
		guard nonCancelTagCount > 0, nonCancelTagCount <= maximumAllowedTagScalars else {
			return []
		}

		for index in tagIndices.dropLast() {
			if !isAllowedSubdivisionTag(scalars[index]) {
				return []
			}
		}

		return Set(tagIndices)
	}

	private static func isCombiningMark(_ scalar: UnicodeScalar) -> Bool {
		CharacterSet.nonBaseCharacters.contains(scalar)
	}

	private static func isVariationSelector(_ scalar: UnicodeScalar) -> Bool {
		(0xFE00...0xFE0F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value)
	}

	private static func isBidiOverride(_ scalar: UnicodeScalar) -> Bool {
		(0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
	}

	private static func isTagScalar(_ scalar: UnicodeScalar) -> Bool {
		(0xE0001...0xE007F).contains(scalar.value)
	}

	private static func isAllowedSubdivisionTag(_ scalar: UnicodeScalar) -> Bool {
		(0xE0030...0xE0039).contains(scalar.value) || (0xE0061...0xE007A).contains(scalar.value)
	}
}

public extension String {
	func sanitizedForExtraction() -> UnicodeSanitizationResult {
		UnicodeAbuseSanitizer.sanitize(self)
	}
}
