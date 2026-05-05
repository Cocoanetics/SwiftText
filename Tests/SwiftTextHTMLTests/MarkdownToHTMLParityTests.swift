import Testing
@testable import SwiftTextHTML
import SwiftTextMarkdown

/// Byte-exact parity assertions between the legacy `MarkdownToHTML.convert` and
/// the swift-markdown-backed `SwiftMarkdownHTMLRenderer.convert`. These guard
/// the cutover in phase 6: as long as every fixture produces identical output
/// from both implementations, swapping the legacy parser for the visitor is a
/// no-op for callers.
@Suite("MarkdownToHTML parity (issue #15)")
struct MarkdownToHTMLParityTests {

	private func parity(_ markdown: String, sourceLocation: SourceLocation = #_sourceLocation) {
		let legacy = MarkdownToHTML.convert(markdown)
		let visitor = SwiftMarkdownHTMLRenderer.convert(markdown)
		#expect(legacy == visitor, "Output diverged for fixture: \(markdown.debugDescription)", sourceLocation: sourceLocation)
	}

	// MARK: - Headings & paragraphs

	@Test func headingsParity() {
		parity("# Hello")
		parity("## Sub")
		parity("###### Deep")
	}

	@Test func paragraphsParity() {
		parity("First paragraph.\n\nSecond paragraph.")
		parity("Just one paragraph.")
	}

	// MARK: - Inline formatting

	@Test func boldParity() {
		parity("This is **bold** text.")
		parity("This is __bold__ text.")
	}

	@Test func italicParity() {
		parity("This is *italic* text.")
	}

	@Test func inlineCodeParity() {
		parity("Use `print()` here.")
	}

	@Test func linksParity() {
		parity("Visit [Example](https://example.com).")
	}

	@Test func imagesParity() {
		parity("![Alt](https://img.png)")
	}

	// MARK: - Block elements

	@Test func blockquoteParity() {
		parity("> Quoted text")
	}

	@Test func githubAlertNoteParity() {
		parity("> [!NOTE]\n> Highlights information that users should take into account.")
	}

	@Test func githubAlertWarningInlineParity() {
		parity("> [!WARNING] Proceed carefully")
	}

	@Test func unorderedListParity() {
		parity("- Apple\n- Banana\n- Cherry")
	}

	@Test func orderedListParity() {
		parity("1. First\n2. Second\n3. Third")
	}

	@Test func horizontalRuleParity() {
		parity("---")
		parity("***")
		parity("___")
	}

	// MARK: - Code blocks

	@Test func fencedCodeBlockParity() {
		parity("```\nlet x = 1\n```")
	}

	@Test func fencedCodeBlockWithLanguageParity() {
		parity("```json\n{\n  \"test\": 1\n}\n```")
	}

	@Test func fencedCodeBlockPreservesIndentationParity() {
		parity("```python\ndef foo():\n    return 42\n```")
	}

	@Test func fencedCodeBlockEscapesHTMLParity() {
		parity("```html\n<div>&amp;</div>\n```")
	}

	@Test func fencedCodeBlockAmongParagraphsParity() {
		parity("Before.\n\n```\ncode\n```\n\nAfter.")
	}

	// MARK: - Tables

	@Test func basicPipeTableParity() {
		parity("""
		| h1 | h2 |
		| --- | --- |
		| a  | b  |
		""")
	}

	@Test func pipeTableWithAlignmentParity() {
		parity("""
		| L | C | R |
		| :-- | :--: | --: |
		| a | b | c |
		""")
	}

	// MARK: - HTML escaping

	@Test func htmlEscapingParity() {
		parity("Use <div> & \"quotes\"")
	}
}
