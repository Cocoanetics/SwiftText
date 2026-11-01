import Testing

@testable import SwiftTextMarkdown

@Suite("Paragraph alignment read from a stylesheet")
struct MarkdownTextAlignmentTests {
	@Test("`p, li { text-align: justify }` justifies paragraphs and list items")
	func justifyBoth() {
		let alignment = MarkdownTextAlignment(css: "p, li { text-align: justify; }")
		#expect(alignment == MarkdownTextAlignment(paragraph: .justify, listItem: .justify))
	}

	@Test("No stylesheet, or no `text-align`, leaves the alignment unspecified")
	func unspecified() {
		#expect(MarkdownTextAlignment(css: "") == .unspecified)
		#expect(MarkdownTextAlignment(css: "p { color: #333; } li { margin: 0 }") == .unspecified)
	}

	@Test("Rules win as in CSS: the later rule, then the more specific, then `!important`")
	func cascade() {
		#expect(MarkdownTextAlignment(css: "p { text-align: left } p { text-align: right }").paragraph == .right)
		#expect(MarkdownTextAlignment(css: "body p { text-align: center } p { text-align: right }").paragraph == .center)
		#expect(MarkdownTextAlignment(css: "p { text-align: justify !important } body p { text-align: left }").paragraph == .justify)
		#expect(MarkdownTextAlignment(css: "p { text-align: left; text-align: justify }").paragraph == .justify)
	}

	@Test("Boxes, quotes, headings, cells and `@media` rules don't count")
	func ignoredSelectors() {
		let alignment = MarkdownTextAlignment(css: """
		.markdown-alert p { text-align: left }
		blockquote p { text-align: right }
		h1 { text-align: center }
		td, th { text-align: right }
		p.lead, p:first-child, #intro, li > p, div li { text-align: center }
		@media print { p { text-align: right } }
		""")
		#expect(alignment == .unspecified)
	}

	@Test("`body` and `html` are a fallback for paragraphs only, below a `p` rule")
	func rootFallback() {
		#expect(MarkdownTextAlignment(css: "body { text-align: justify }") == MarkdownTextAlignment(paragraph: .justify))
		#expect(MarkdownTextAlignment(css: "html { text-align: center }").paragraph == .center)
		#expect(MarkdownTextAlignment(css: "p { text-align: left } body { text-align: justify }").paragraph == .left)
	}

	@Test("List items take their own rule, from `ol li` or `ul li` too")
	func listItems() {
		#expect(MarkdownTextAlignment(css: "ul li { text-align: justify }") == MarkdownTextAlignment(listItem: .justify))
		#expect(MarkdownTextAlignment(css: "p { text-align: left } li { text-align: justify }")
			== MarkdownTextAlignment(paragraph: .left, listItem: .justify))
	}

	@Test("`start` and `end` read as left and right; unknown values are ignored")
	func values() {
		#expect(MarkdownTextAlignment(css: "p { text-align: start } li { text-align: END }")
			== MarkdownTextAlignment(paragraph: .left, listItem: .right))
		#expect(MarkdownTextAlignment(css: "p { text-align: justify } p { text-align: match-parent }").paragraph == .justify)
	}

	@Test("Comments are skipped")
	func comments() {
		#expect(MarkdownTextAlignment(css: "/* p { text-align: right } */ p { text-align: /* book */ justify }").paragraph == .justify)
	}
}
