import Testing
@testable import SwiftTextHTML

/// Coverage tests for Markdown features that the legacy hand-rolled parser
/// didn't support but become available for free once we delegate to
/// swift-markdown. These features are now reachable via the public
/// `MarkdownToHTML.convert` API.
@Suite("Markdown GFM extensions")
struct MarkdownGFMExtensionsTests {

	@Test func strikethrough() {
		let html = MarkdownToHTML.convert("This is ~~struck~~ text.")
		#expect(html.contains("<del>struck</del>"))
	}

	@Test func taskListsUnchecked() {
		let html = MarkdownToHTML.convert("- [ ] Todo")
		#expect(html.contains(#"<li class="task-list-item"><input type="checkbox" disabled> Todo</li>"#))
	}

	@Test func taskListsChecked() {
		let html = MarkdownToHTML.convert("- [x] Done")
		#expect(html.contains(#"<input type="checkbox" disabled checked>"#))
		#expect(html.contains("Done"))
	}

	@Test func angleBracketAutolink() {
		// Angle-bracket autolinks are CommonMark and parse natively.
		let html = MarkdownToHTML.convert("Visit <https://example.com>.")
		#expect(html.contains(#"<a href="https://example.com">https://example.com</a>"#))
	}

	@Test func bareURLDoesNotAutolinkYet() {
		// swift-markdown's default Document(parsing:) does not enable the GFM
		// bare-URL autolink extension. The legacy parser didn't either, so this
		// is a documented limitation rather than a regression. If we want bare
		// autolinks later, we'd post-process Text nodes with a URL regex.
		let html = MarkdownToHTML.convert("Visit https://example.com today.")
		#expect(!html.contains("<a href"))
		#expect(html.contains("https://example.com"))
	}

	@Test func hardLineBreak() {
		// Two trailing spaces + newline = hard break in GFM.
		let html = MarkdownToHTML.convert("Line one  \nLine two")
		#expect(html.contains("<br>"))
	}

	@Test func setextHeading() {
		let html = MarkdownToHTML.convert("Title\n=====")
		#expect(html.contains("<h1>Title</h1>"))
	}

	@Test func indentedCodeBlock() {
		let html = MarkdownToHTML.convert("    let x = 1")
		#expect(html.contains("<pre><code>"))
		#expect(html.contains("let x = 1"))
	}

	@Test func linkReferenceDefinition() {
		let markdown = "See [the example][ref].\n\n[ref]: https://example.com"
		let html = MarkdownToHTML.convert(markdown)
		#expect(html.contains(#"<a href="https://example.com">the example</a>"#))
	}

	@Test func escapeSequences() {
		let html = MarkdownToHTML.convert(#"Literal \*asterisks\* here"#)
		// `\*` should NOT trigger emphasis.
		#expect(!html.contains("<em>"))
		#expect(html.contains("*asterisks*"))
	}

	@Test func nestedListsMixedMarkers() {
		let markdown = """
		- Top
		  1. One
		  2. Two
		- Sibling
		"""
		let html = MarkdownToHTML.convert(markdown)
		#expect(html.contains("<ul>"))
		#expect(html.contains("<ol>"))
		#expect(html.contains("Top"))
		#expect(html.contains("Sibling"))
	}

	@Test func doccStyleAside() {
		// `> Tip: text` is the DocC plain-text aside form. We render it through
		// the same `<aside class="markdown-alert-tip">` shape as a GitHub alert.
		let html = MarkdownToHTML.convert("> Tip: Use `--watch` for live reload.")
		#expect(html.contains(#"<aside class="markdown-alert markdown-alert-tip""#))
		#expect(html.contains(#"<p class="markdown-alert-title">Tip</p>"#))
		#expect(html.contains("<code>--watch</code>"))
	}

	@Test func doccStyleNoteWithMultipleLines() {
		let markdown = """
		> Note: First line.
		> Second line.
		"""
		let html = MarkdownToHTML.convert(markdown)
		#expect(html.contains(#"markdown-alert-note"#))
		#expect(html.contains("First line."))
		#expect(html.contains("Second line."))
	}

	@Test func defaultStylesheetIncludesNewElementStyles() {
		let css = MarkdownToHTML.defaultStylesheet
		#expect(css.contains("task-list-item"))
		#expect(css.contains("del "))
	}
}
