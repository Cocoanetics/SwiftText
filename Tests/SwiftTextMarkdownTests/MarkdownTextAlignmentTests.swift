import Testing

@testable import SwiftTextMarkdown

@Suite("Text alignment from CSS")
struct MarkdownTextAlignmentTests {
	@Test("`p, li { text-align: justify }` justifies paragraphs and list items")
	func justifiesBoth() {
		let alignment = MarkdownTextAlignment(css: "p, li { text-align: justify; }")
		#expect(alignment.paragraph == .justify)
		#expect(alignment.listItem == .justify)
	}

	@Test("Paragraphs and list items inherit from body; their own rules win")
	func inheritance() {
		let alignment = MarkdownTextAlignment(css: "body { text-align: center } li { text-align: right }")
		#expect(alignment.paragraph == .center)
		#expect(alignment.listItem == .right)
		#expect(MarkdownTextAlignment(css: "ul { text-align: justify } body { text-align: left }").listItem == .justify)
	}

	@Test("Later declarations win unless an earlier one is !important; start/end map to left/right")
	func cascade() {
		#expect(MarkdownTextAlignment(css: "p { text-align: center } p { text-align: end }").paragraph == .right)
		#expect(MarkdownTextAlignment(css: "p { text-align: start !important } p { text-align: justify }").paragraph == .left)
	}

	@Test("Selectors that don't match a plain paragraph, at-rules and other properties are ignored")
	func ignoresOtherRules() {
		let css = """
		.markdown-alert p { text-align: left; }
		blockquote p, p.note { text-align: right; }
		@media print { p { text-align: center; } }
		h1 { text-align: center; }
		p { color: red; text-align: inherit; }
		"""
		#expect(MarkdownTextAlignment(css: css).isEmpty)
	}
}
