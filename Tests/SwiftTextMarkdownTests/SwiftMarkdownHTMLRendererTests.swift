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
		#expect(html.contains("  \"test\": 1"))
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
		#expect(html.contains("&lt;div&gt;"))
		#expect(html.contains("&amp;"))
		// Smart-punctuation reversal restores the literal straight quotes.
		#expect(!html.contains("\u{201C}"))
		#expect(!html.contains("\u{201D}"))
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

	@Test func taskListsRenderAsCheckboxes() {
		let html = SwiftMarkdownHTMLRenderer.convert("- [ ] Todo\n- [x] Done")
		#expect(html.contains("<ul>"))
		#expect(html.contains(#"<li class="task-list-item"><input type="checkbox" disabled> Todo</li>"#))
		#expect(html.contains(#"<li class="task-list-item"><input type="checkbox" disabled checked> Done</li>"#))
	}

	@Test func rawHTMLEscapedByDefault() {
		let block = SwiftMarkdownHTMLRenderer.convert("<p align=\"center\"><img src=\"logo.png\"></p>")
		#expect(block.contains("&lt;p align=\"center\"&gt;"))
		#expect(!block.contains("<img"))

		let inline = SwiftMarkdownHTMLRenderer.convert("before <kbd>K</kbd> after")
		#expect(inline.contains("&lt;kbd&gt;K&lt;/kbd&gt;"))
	}

	@Test func rawHTMLPassThroughOption() {
		// block-level raw HTML is emitted verbatim
		let block = SwiftMarkdownHTMLRenderer.convert(
			"<p align=\"center\"> <img src=\"Documentation/Logo.png\" alt=\"Logo\" width=\"400\"/> </p>",
			options: .passThroughRawHTML)
		#expect(block.contains("<p align=\"center\">"))
		#expect(block.contains("<img src=\"Documentation/Logo.png\" alt=\"Logo\" width=\"400\"/>"))

		// inline raw HTML inside a paragraph is emitted verbatim too
		let inline = SwiftMarkdownHTMLRenderer.convert(
			"press <kbd>K</kbd> to continue", options: .passThroughRawHTML)
		#expect(inline.contains("press <kbd>K</kbd> to continue"))

		// markdown-level escaping of text is unaffected
		let mixed = SwiftMarkdownHTMLRenderer.convert(
			"a < b and <sub>x</sub>", options: .passThroughRawHTML)
		#expect(mixed.contains("a &lt; b"))
		#expect(mixed.contains("<sub>x</sub>"))
	}
}
