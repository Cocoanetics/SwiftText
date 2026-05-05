import Testing
@testable import SwiftTextMarkdown

@Suite("SwiftMarkdownHTMLRenderer")
struct SwiftMarkdownHTMLRendererTests {

	@Test func headings() {
		#expect(SwiftMarkdownHTMLRenderer.convert("# Hello") == "<h1>Hello</h1>")
		#expect(SwiftMarkdownHTMLRenderer.convert("## Sub") == "<h2>Sub</h2>")
		#expect(SwiftMarkdownHTMLRenderer.convert("###### Deep") == "<h6>Deep</h6>")
	}

	@Test func paragraphs() {
		let html = SwiftMarkdownHTMLRenderer.convert("First paragraph.\n\nSecond paragraph.")
		#expect(html.contains("<p>First paragraph.</p>"))
		#expect(html.contains("<p>Second paragraph.</p>"))
	}

	@Test func bold() {
		#expect(SwiftMarkdownHTMLRenderer.convert("This is **bold** text.").contains("<strong>bold</strong>"))
		#expect(SwiftMarkdownHTMLRenderer.convert("This is __bold__ text.").contains("<strong>bold</strong>"))
	}

	@Test func italic() {
		#expect(SwiftMarkdownHTMLRenderer.convert("This is *italic* text.").contains("<em>italic</em>"))
	}

	@Test func inlineCode() {
		#expect(SwiftMarkdownHTMLRenderer.convert("Use `print()` here.").contains("<code>print()</code>"))
	}

	@Test func links() {
		let html = SwiftMarkdownHTMLRenderer.convert("Visit [Example](https://example.com).")
		#expect(html.contains(#"<a href="https://example.com">Example</a>"#))
	}

	@Test func images() {
		let html = SwiftMarkdownHTMLRenderer.convert("![Alt](https://img.png)")
		#expect(html.contains(#"<img src="https://img.png" alt="Alt">"#))
	}

	@Test func blockquote() {
		let html = SwiftMarkdownHTMLRenderer.convert("> Quoted text")
		#expect(html.contains("<blockquote>"))
		#expect(html.contains("Quoted text"))
	}

	@Test func githubAlertBox() {
		let markdown = "> [!NOTE]\n> Highlights information that users should take into account."
		let html = SwiftMarkdownHTMLRenderer.convert(markdown)
		#expect(html.contains(#"<aside class="markdown-alert markdown-alert-note" data-alert="note" role="note">"#))
		#expect(html.contains(#"<p class="markdown-alert-title">Note</p>"#))
		#expect(html.contains("Highlights information that users should take into account."))
	}

	@Test func githubAlertBoxWithInlineMarkerContent() {
		let markdown = "> [!WARNING] Proceed carefully"
		let html = SwiftMarkdownHTMLRenderer.convert(markdown)
		#expect(html.contains(#"markdown-alert-warning"#))
		#expect(html.contains(#"role="alert""#))
		#expect(html.contains("Proceed carefully"))
	}

	@Test func unorderedList() {
		let html = SwiftMarkdownHTMLRenderer.convert("- Apple\n- Banana\n- Cherry")
		#expect(html.contains("<ul>"))
		#expect(html.contains("<li>Apple</li>"))
		#expect(html.contains("<li>Cherry</li>"))
	}

	@Test func orderedList() {
		let html = SwiftMarkdownHTMLRenderer.convert("1. First\n2. Second\n3. Third")
		#expect(html.contains("<ol>"))
		#expect(html.contains("<li>First</li>"))
	}

	@Test func fencedCodeBlock() {
		let html = SwiftMarkdownHTMLRenderer.convert("```\nlet x = 1\n```")
		#expect(html == "<pre><code>let x = 1</code></pre>")
	}

	@Test func fencedCodeBlockWithLanguage() {
		let html = SwiftMarkdownHTMLRenderer.convert("```json\n{\n  \"test\": 1\n}\n```")
		#expect(html.contains("<pre><code class=\"language-json\">"))
		// swift-markdown / cmark-gfm escapes `"` to `&quot;` even inside <code>;
		// our hand-rolled parser leaves the `"` literal. Capture the actual behavior.
		#expect(html.contains("  &quot;test&quot;: 1"))
		#expect(html.contains("</code></pre>"))
	}

	@Test func fencedCodeBlockPreservesIndentation() {
		let html = SwiftMarkdownHTMLRenderer.convert("```python\ndef foo():\n    return 42\n```")
		#expect(html.contains("    return 42"))
	}

	@Test func fencedCodeBlockEscapesHTML() {
		let html = SwiftMarkdownHTMLRenderer.convert("```html\n<div>&amp;</div>\n```")
		#expect(html.contains("&lt;div&gt;&amp;amp;&lt;/div&gt;"))
	}

	@Test func fencedCodeBlockAmongParagraphs() {
		let html = SwiftMarkdownHTMLRenderer.convert("Before.\n\n```\ncode\n```\n\nAfter.")
		#expect(html.contains("<p>Before.</p>"))
		#expect(html.contains("<pre><code>code</code></pre>"))
		#expect(html.contains("<p>After.</p>"))
	}

	@Test func horizontalRule() {
		#expect(SwiftMarkdownHTMLRenderer.convert("---") == "<hr>")
		#expect(SwiftMarkdownHTMLRenderer.convert("***") == "<hr>")
		#expect(SwiftMarkdownHTMLRenderer.convert("___") == "<hr>")
	}

	@Test func htmlEscaping() {
		let html = SwiftMarkdownHTMLRenderer.convert("Use <div> & \"quotes\"")
		// Divergence vs MarkdownToHTML: swift-markdown / cmark treats `<div>` as raw
		// HTML per CommonMark, so it disappears from the AST as an InlineHTML node
		// (we don't render those). Our hand-rolled parser escapes `<` literally.
		#expect(!html.contains("&lt;div&gt;"))
		#expect(html.contains("&amp;"))
		// Divergence: cmark-gfm enables smart punctuation by default, turning
		// straight quotes into typographic quotes.
		#expect(html.contains("\u{201C}quotes\u{201D}"))
	}

	// MARK: - Coverage tests beyond the current parser

	@Test func strikethroughIsParsedAndRendered() {
		let html = SwiftMarkdownHTMLRenderer.convert("This is ~~struck~~ text.")
		// Finding for issue #15: swift-markdown's default `Document(parsing:)` DOES
		// parse `~~...~~` into a Strikethrough node, so once we add a visit method
		// this is essentially free. The current MarkdownToHTML doesn't support it
		// at all — adopting swift-markdown closes that gap.
		#expect(html.contains("<del>struck</del>"))
	}

	@Test func tablesAreParsed() {
		let markdown = """
		| h1 | h2 |
		| --- | --- |
		| a  | b  |
		"""
		let html = SwiftMarkdownHTMLRenderer.convert(markdown)
		// Tables aren't lowered to HTML by the prototype renderer yet — confirm we
		// at least don't throw and produce some output.
		#expect(!html.isEmpty)
	}

	@Test func taskListsAreParsedAsListItems() {
		let html = SwiftMarkdownHTMLRenderer.convert("- [ ] Todo\n- [x] Done")
		#expect(html.contains("<ul>"))
		#expect(html.contains("<li>"))
	}
}
