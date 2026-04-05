import Foundation
import SwiftTextCore
import Testing

struct UnicodeAbuseSanitizerTests {
	@Test
	func stripsBidirectionalOverridesAndInvalidTags() {
		let source = "safe\u{202E}text\u{202C}\u{E0061}\u{E007F}"
		let result = UnicodeAbuseSanitizer.sanitize(source)

		#expect(result.text == "safetext")
		#expect(result.report.hasBidiOverrides)
		#expect(result.report.hasTagAbuse)
		#expect(result.report.containsAbuse)
	}

	@Test
	func trimsCombiningMarkBombs() {
		let marks = String(repeating: "\u{0301}", count: 20)
		let source = "A\(marks)"
		let result = UnicodeAbuseSanitizer.sanitize(source)

		#expect(result.text.unicodeScalars.count == 15)
		#expect(result.report.excessiveCombiningMarks == 2)
		#expect(result.report.containsAbuse)
	}

	@Test
	func preservesLegitimateEmojiZWJSequences() {
		let source = "Family: 👨‍👩‍👧‍👦"
		let result = UnicodeAbuseSanitizer.sanitize(source)

		#expect(result.text == source)
		#expect(!result.report.containsAbuse)
	}

	@Test
	func preservesVariationSelectorsInValidEmojiZWJSequences() {
		let source = "Comment: 👁️‍🗨️"
		let result = UnicodeAbuseSanitizer.sanitize(source)

		#expect(result.text == source)
		#expect(!result.report.containsAbuse)
	}

	@Test
	func trimsRepeatedVariationSelectorSpam() {
		let source = "Alert: ⚠️\u{FE0F}\u{FE0F}"
		let result = UnicodeAbuseSanitizer.sanitize(source)

		#expect(result.text == "Alert: ⚠️")
	}
}
