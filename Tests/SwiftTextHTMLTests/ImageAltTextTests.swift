import Testing
@testable import SwiftTextHTML

/// Regression tests for image alt-text extraction when the alt content contains
/// nested inline formatting (PR #16 review).
@Suite("Image alt text")
struct ImageAltTextTests {

	@Test func emphasizedAltTextSurvivesAsPlainText() {
		let html = MarkdownToHTML.convert("![*diagram*](img.png)")
		// The alt attribute carries the plain-text rendering of the description,
		// so emphasis markup is unwrapped rather than dropping the inner text.
		#expect(html.contains(#"alt="diagram""#))
		#expect(html.contains(#"src="img.png""#))
	}

	@Test func strongAltTextSurvives() {
		let html = MarkdownToHTML.convert("![**important**](img.png)")
		#expect(html.contains(#"alt="important""#))
	}

	@Test func mixedFormattingAltText() {
		let html = MarkdownToHTML.convert("![*part one* part two `code`](img.png)")
		#expect(html.contains(#"alt="part one part two code""#))
	}

	@Test func plainAltTextStillWorks() {
		let html = MarkdownToHTML.convert("![Alt text](img.png)")
		#expect(html.contains(#"alt="Alt text""#))
	}

	@Test func emptyAltText() {
		let html = MarkdownToHTML.convert("![](img.png)")
		#expect(html.contains(#"alt="""#))
	}
}
