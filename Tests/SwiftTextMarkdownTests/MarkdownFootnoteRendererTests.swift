import Testing
@testable import SwiftTextMarkdown

@Suite("MarkdownFootnoteRenderer")
struct MarkdownFootnoteRendererTests {

	@Test func basicReferenceAndDefinition() {
		let html = MarkdownFootnoteRenderer.convert("Hello[^a].\n\n[^a]: The note")
		#expect(html == "<p>Hello<sup><a href=\"#fn-1\" id=\"ref-1\">[1]</a></sup>.</p>\n"
			+ "<div class=\"footnote-definition\" id=\"fn-1\"><strong>[1]:</strong> The note</div>")
	}

	@Test func numbersAssignedInOrderOfFirstReference() {
		let input = "B[^beta] then A[^alpha].\n\n[^alpha]: Alpha note\n[^beta]: Beta note"
		let html = MarkdownFootnoteRenderer.convert(input)
		#expect(html.contains("B<sup><a href=\"#fn-1\" id=\"ref-1\">[1]</a></sup>"))
		#expect(html.contains("A<sup><a href=\"#fn-2\" id=\"ref-2\">[2]</a></sup>"))
		// Definitions block is ordered by footnote number, not source order.
		#expect(html.contains("<div class=\"footnote-definition\" id=\"fn-1\"><strong>[1]:</strong> Beta note</div>\n"
			+ "<div class=\"footnote-definition\" id=\"fn-2\"><strong>[2]:</strong> Alpha note</div>"))
	}

	@Test func repeatedReferenceGetsUniqueAnchorIDs() {
		let html = MarkdownFootnoteRenderer.convert("First[^n] and second[^n].\n\n[^n]: Note")
		#expect(html.contains("<a href=\"#fn-1\" id=\"ref-1\">[1]</a>"))
		#expect(html.contains("<a href=\"#fn-1\" id=\"ref-1-2\">[1]</a>"))
	}

	@Test func orphanReferenceStaysLiteral() {
		// No definitions at all — fast path, nothing substituted.
		#expect(MarkdownFootnoteRenderer.convert("Hello[^ghost].") == "<p>Hello[^ghost].</p>")

		// Orphan alongside a real footnote — only the real one is substituted.
		let html = MarkdownFootnoteRenderer.convert("Real[^r] and ghost[^g].\n\n[^r]: exists")
		#expect(html.contains("ghost[^g]."))
		#expect(html.contains("Real<sup><a href=\"#fn-1\" id=\"ref-1\">[1]</a></sup>"))
		#expect(!html.contains("fn-2"))
	}

	@Test func unreferencedDefinitionIsDropped() {
		let html = MarkdownFootnoteRenderer.convert("No refs here.\n\n[^unused]: Gone")
		#expect(html == "<p>No refs here.</p>")
		#expect(!html.contains("Gone"))
	}

	@Test func referenceInsideInlineCodeIsNotSubstituted() {
		let html = MarkdownFootnoteRenderer.convert("Use `[^c]` and real[^c].\n\n[^c]: Code note")
		#expect(html.contains("<code>[^c]</code>"))
		#expect(html.contains("real<sup><a href=\"#fn-1\" id=\"ref-1\">[1]</a></sup>"))
	}

	@Test func definitionWithContinuationLines() {
		let input = "Text[^long].\n\n[^long]: First line\n    continued line"
		let html = MarkdownFootnoteRenderer.convert(input)
		#expect(html.contains("<div class=\"footnote-definition\" id=\"fn-1\">"))
		#expect(html.contains("First line"))
		#expect(html.contains("continued line"))
	}

	@Test func multiParagraphDefinition() {
		let input = "Text[^m].\n\n[^m]: First para.\n\n    Second para."
		let html = MarkdownFootnoteRenderer.convert(input)
		// Multi-block body keeps the label in its own paragraph.
		#expect(html.contains("<div class=\"footnote-definition\" id=\"fn-1\"><p><strong>[1]:</strong></p>"))
		#expect(html.contains("<p>First para.</p>"))
		#expect(html.contains("<p>Second para.</p>"))
	}

	@Test func nestedReferenceInsideDefinition() {
		let input = "Main[^a].\n\n[^a]: See also[^b].\n[^b]: Other note."
		let html = MarkdownFootnoteRenderer.convert(input)
		#expect(html.contains("<div class=\"footnote-definition\" id=\"fn-1\"><strong>[1]:</strong> See also<sup><a href=\"#fn-2\" id=\"ref-2\">[2]</a></sup>.</div>"))
		#expect(html.contains("<div class=\"footnote-definition\" id=\"fn-2\"><strong>[2]:</strong> Other note.</div>"))
	}

	@Test func nestedReferenceToEarlierDefinition() {
		// [^b] is defined before [^a] in source but only referenced from inside
		// [^a]'s body — it must still be rendered.
		let input = "Main[^a].\n\n[^b]: Other note.\n[^a]: See also[^b]."
		let html = MarkdownFootnoteRenderer.convert(input)
		#expect(html.contains("<div class=\"footnote-definition\" id=\"fn-1\"><strong>[1]:</strong> See also<sup><a href=\"#fn-2\" id=\"ref-2\">[2]</a></sup>.</div>"))
		#expect(html.contains("<div class=\"footnote-definition\" id=\"fn-2\"><strong>[2]:</strong> Other note.</div>"))
	}

	@Test func rawHTMLEscapedByDefaultWithFootnotes() {
		let input = "Press <kbd>K</kbd> to open[^k].\n\n[^k]: Keyboard note with <sub>html</sub>."
		let html = MarkdownFootnoteRenderer.convert(input)
		#expect(html.contains("&lt;kbd&gt;K&lt;/kbd&gt;"))
		#expect(html.contains("&lt;sub&gt;html&lt;/sub&gt;"))
		#expect(html.contains("<sup><a href=\"#fn-1\" id=\"ref-1\">[1]</a></sup>"))
	}

	@Test func passThroughRawHTMLOptionReachesBodyAndDefinitions() {
		let input = "Press <kbd>K</kbd> to open[^k].\n\n[^k]: Keyboard note with <sub>html</sub>."
		let html = MarkdownFootnoteRenderer.convert(input, options: .passThroughRawHTML)
		#expect(html.contains("Press <kbd>K</kbd> to open"))
		#expect(html.contains("Keyboard note with <sub>html</sub>."))
		#expect(html.contains("<sup><a href=\"#fn-1\" id=\"ref-1\">[1]</a></sup>"))
	}

	@Test func passThroughRawHTMLOptionOnFastPath() {
		// No footnote definitions -> fast path must still forward the options.
		let html = MarkdownFootnoteRenderer.convert(
			"<p align=\"center\"><img src=\"logo.png\"></p>", options: .passThroughRawHTML)
		#expect(html.contains("<p align=\"center\"><img src=\"logo.png\"></p>"))
	}

	@Test func passThroughRawHTMLBlockAlongsideFootnotes() {
		let input = "Intro[^1].\n\n<div class=\"x\">raw</div>\n\n[^1]: Note"
		let html = MarkdownFootnoteRenderer.convert(input, options: .passThroughRawHTML)
		#expect(html.contains("<div class=\"x\">raw</div>"))
		#expect(html.contains("<div class=\"footnote-definition\" id=\"fn-1\"><strong>[1]:</strong> Note</div>"))
	}
}
