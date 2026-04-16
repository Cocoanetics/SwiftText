import Testing
@testable import SwiftTextHTML

@Suite("MarkdownToHTML")
struct MarkdownToHTMLTests {

	@Test func headings() {
		#expect(MarkdownToHTML.convert("# Hello") == "<h1>Hello</h1>")
		#expect(MarkdownToHTML.convert("## Sub") == "<h2>Sub</h2>")
		#expect(MarkdownToHTML.convert("###### Deep") == "<h6>Deep</h6>")
	}

	@Test func paragraphs() {
		let input = "First paragraph.\n\nSecond paragraph."
		let html = MarkdownToHTML.convert(input)
		#expect(html.contains("<p>First paragraph.</p>"))
		#expect(html.contains("<p>Second paragraph.</p>"))
	}

	@Test func bold() {
		#expect(MarkdownToHTML.convert("This is **bold** text.").contains("<strong>bold</strong>"))
		#expect(MarkdownToHTML.convert("This is __bold__ text.").contains("<strong>bold</strong>"))
	}

	@Test func italic() {
		#expect(MarkdownToHTML.convert("This is *italic* text.").contains("<em>italic</em>"))
	}

	@Test func inlineCode() {
		#expect(MarkdownToHTML.convert("Use `print()` here.").contains("<code>print()</code>"))
	}

	@Test func links() {
		let html = MarkdownToHTML.convert("Visit [Example](https://example.com).")
		#expect(html.contains(#"<a href="https://example.com">Example</a>"#))
	}

	@Test func images() {
		let html = MarkdownToHTML.convert("![Alt](https://img.png)")
		#expect(html.contains(#"<img src="https://img.png" alt="Alt">"#))
	}

	@Test func blockquote() {
		let html = MarkdownToHTML.convert("> Quoted text")
		#expect(html.contains("<blockquote>"))
		#expect(html.contains("Quoted text"))
	}

	@Test func unorderedList() {
		let input = "- Apple\n- Banana\n- Cherry"
		let html = MarkdownToHTML.convert(input)
		#expect(html.contains("<ul>"))
		#expect(html.contains("<li>Apple</li>"))
		#expect(html.contains("<li>Cherry</li>"))
	}

	@Test func orderedList() {
		let input = "1. First\n2. Second\n3. Third"
		let html = MarkdownToHTML.convert(input)
		#expect(html.contains("<ol>"))
		#expect(html.contains("<li>First</li>"))
	}

	@Test func fencedCodeBlock() {
		let input = "```\nlet x = 1\n```"
		let html = MarkdownToHTML.convert(input)
		#expect(html == "<pre><code>let x = 1</code></pre>")
	}

	@Test func fencedCodeBlockWithLanguage() {
		let input = "```json\n{\n  \"test\": 1\n}\n```"
		let html = MarkdownToHTML.convert(input)
		#expect(html.contains("<pre><code class=\"language-json\">"))
		#expect(html.contains("  \"test\": 1"))
		#expect(html.contains("</code></pre>"))
	}

	@Test func fencedCodeBlockPreservesIndentation() {
		let input = "```python\ndef foo():\n    return 42\n```"
		let html = MarkdownToHTML.convert(input)
		#expect(html.contains("    return 42"))
	}

	@Test func fencedCodeBlockEscapesHTML() {
		let input = "```html\n<div>&amp;</div>\n```"
		let html = MarkdownToHTML.convert(input)
		#expect(html.contains("&lt;div&gt;&amp;amp;&lt;/div&gt;"))
	}

	@Test func fencedCodeBlockAmongParagraphs() {
		let input = "Before.\n\n```\ncode\n```\n\nAfter."
		let html = MarkdownToHTML.convert(input)
		#expect(html.contains("<p>Before.</p>"))
		#expect(html.contains("<pre><code>code</code></pre>"))
		#expect(html.contains("<p>After.</p>"))
	}

	@Test func horizontalRule() {
		#expect(MarkdownToHTML.convert("---") == "<hr>")
		#expect(MarkdownToHTML.convert("***") == "<hr>")
		#expect(MarkdownToHTML.convert("___") == "<hr>")
	}

	@Test func htmlEscaping() {
		let html = MarkdownToHTML.convert("Use <div> & \"quotes\"")
		#expect(html.contains("&lt;div&gt;"))
		#expect(html.contains("&amp;"))
	}

	@Test func stripToPlainText() {
		let md = "# Title\n\nThis is **bold** and *italic* with a [link](https://x.com).\n\n> Quote\n\n- Item"
		let text = MarkdownToHTML.stripToPlainText(md)
		#expect(!text.contains("**"))
		#expect(!text.contains("*"))
		#expect(!text.contains("[link]"))
		#expect(!text.contains("#"))
		#expect(text.contains("Title"))
		#expect(text.contains("bold"))
		#expect(text.contains("link"))
	}
}
