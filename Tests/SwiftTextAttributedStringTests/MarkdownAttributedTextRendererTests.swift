import Testing
import Markdown
@testable import SwiftTextAttributedString

/// Feature-parity coverage for ``MarkdownAttributedTextRenderer`` — mirrors the
/// surface of `SwiftMarkdownHTMLRenderer` so every Markdown feature the package
/// supports has an attributed-text counterpart.
@Suite("MarkdownAttributedTextRenderer")
struct MarkdownAttributedTextRendererTests {

	// MARK: Helpers

	private func render(
		_ markdown: String, _ options: MarkdownAttributedTextRenderer.Options = []
	) -> AttributedText {
		MarkdownAttributedTextRenderer.convert(markdown, options: options)
	}

	/// The first run whose text equals `text`.
	private func run(_ text: String, in attributed: AttributedText) -> AttributedText.Run? {
		attributed.runs.first { $0.text == text }
	}

	// MARK: Block structure

	@Test func headingsCarryLevel() {
		for level in 1...6 {
			let hashes = String(repeating: "#", count: level)
			let attributed = render("\(hashes) Title")
			#expect(attributed.string == "Title")
			#expect(attributed.runs.first?.attributes.paragraph.kind == .heading(level: level))
		}
	}

	@Test func paragraphsAreSeparatedByASingleNewline() {
		let attributed = render("First paragraph.\n\nSecond paragraph.")
		#expect(attributed.string == "First paragraph.\nSecond paragraph.")
		// No trailing terminator after the final paragraph.
		#expect(attributed.runs.last?.text == "Second paragraph.")
	}

	@Test func bodyParagraphHasBodyKind() {
		let attributed = render("Just text.")
		#expect(attributed.runs.allSatisfy { $0.attributes.paragraph.kind == .body })
	}

	// MARK: Inline emphasis

	@Test func boldItalicStrikethrough() {
		let attributed = render("Plain **bold** *italic* ~~struck~~ end.")
		#expect(run("bold", in: attributed)?.attributes.bold == true)
		#expect(run("italic", in: attributed)?.attributes.italic == true)
		#expect(run("struck", in: attributed)?.attributes.strikethrough == true)
		#expect(attributed.string == "Plain bold italic struck end.")
	}

	@Test func nestedEmphasisCombinesTraits() {
		let attributed = render("***both***")
		let both = run("both", in: attributed)
		#expect(both?.attributes.bold == true)
		#expect(both?.attributes.italic == true)
	}

	@Test func inlineCodeIsMonospacedAndNotSmartPuncted() {
		let attributed = render("Call `a -- b` now.")
		let code = run("a -- b", in: attributed)
		#expect(code?.attributes.code == true)
		// Smart-punct must not touch code spans.
		#expect(code?.text == "a -- b")
	}

	// MARK: Links & images

	@Test func linkCarriesDestination() {
		let attributed = render("See [the site](https://example.com).")
		#expect(run("the site", in: attributed)?.attributes.link == "https://example.com")
	}

	@Test func autolinkBecomesLink() {
		let attributed = render("<https://example.com>")
		let linkRun = attributed.runs.first { $0.attributes.link != nil }
		#expect(linkRun?.attributes.link == "https://example.com")
		#expect(linkRun?.text == "https://example.com")
	}

	@Test func imageBecomesAttachmentWithAltFallback() {
		let attributed = render("![A diagram](diagram.png)")
		guard case let .image(source, alt, _)? = attributed.runs.first?.attributes.attachment else {
			Issue.record("expected an image attachment")
			return
		}
		#expect(source == "diagram.png")
		#expect(alt == "A diagram")
		#expect(attributed.string == "A diagram")
	}

	@Test func imageAltKeepsNestedInlineText() {
		let attributed = render("![*emphasized* alt](x.png)")
		guard case let .image(_, alt, _)? = attributed.runs.first?.attributes.attachment else {
			Issue.record("expected an image attachment")
			return
		}
		#expect(alt == "emphasized alt")
	}

	// MARK: Lists

	@Test func unorderedListMarkersAndContext() {
		let attributed = render("- one\n- two")
		// Skip the paragraph-terminator newlines, which share the list paragraph style.
		let items = attributed.runs.filter { $0.attributes.paragraph.list != nil && $0.text != "\n" }
		#expect(items.map(\.text) == ["one", "two"])
		#expect(items.allSatisfy { $0.attributes.paragraph.list?.ordered == false })
		#expect(items.allSatisfy { $0.attributes.paragraph.list?.marker == "\u{2022} " })
		#expect(items.first?.attributes.paragraph.kind == .listItem)
	}

	@Test func orderedListNumbersMarkers() {
		let attributed = render("1. first\n2. second")
		let markers = attributed.runs.compactMap { $0.text == "\n" ? nil : $0.attributes.paragraph.list?.marker }
		#expect(markers == ["1. ", "2. "])
		let indices = attributed.runs.compactMap { $0.text == "\n" ? nil : $0.attributes.paragraph.list?.index }
		#expect(indices == [1, 2])
	}

	@Test func orderedListRespectsStartIndex() {
		let attributed = render("5. five\n6. six")
		let markers = attributed.runs.compactMap { $0.text == "\n" ? nil : $0.attributes.paragraph.list?.marker }
		#expect(markers == ["5. ", "6. "])
	}

	@Test func taskListCheckboxes() {
		let attributed = render("- [ ] todo\n- [x] done")
		let todo = run("todo", in: attributed)
		let done = run("done", in: attributed)
		#expect(todo?.attributes.paragraph.list?.checkbox == .unchecked)
		#expect(todo?.attributes.paragraph.list?.marker == "\u{2610} ")
		#expect(done?.attributes.paragraph.list?.checkbox == .checked)
		#expect(done?.attributes.paragraph.list?.marker == "\u{2611} ")
	}

	@Test func nestedListsTrackLevel() {
		let attributed = render("- outer\n  - inner")
		#expect(run("outer", in: attributed)?.attributes.paragraph.list?.level == 0)
		#expect(run("inner", in: attributed)?.attributes.paragraph.list?.level == 1)
	}

	// MARK: Code blocks

	@Test func fencedCodeBlockKeepsLanguageAndContent() {
		let attributed = render("```swift\nlet x = 1\nlet y = 2\n```")
		let codeRun = attributed.runs.first { $0.attributes.code }
		#expect(codeRun?.text == "let x = 1\nlet y = 2")
		#expect(codeRun?.attributes.paragraph.kind == .codeBlock(language: "swift"))
	}

	@Test func indentedCodeBlockHasNilLanguage() {
		let attributed = render("    indented code")
		#expect(attributed.runs.first?.attributes.paragraph.kind == .codeBlock(language: nil))
	}

	// MARK: Blockquotes

	@Test func blockquoteSetsQuoteLevel() {
		let attributed = render("> quoted")
		#expect(run("quoted", in: attributed)?.attributes.paragraph.quoteLevel == 1)
	}

	@Test func nestedBlockquoteDeepensQuoteLevel() {
		let attributed = render("> > deep")
		#expect(run("deep", in: attributed)?.attributes.paragraph.quoteLevel == 2)
	}

	// MARK: Alerts

	@Test func githubAlertTitleAndBody() {
		let attributed = render("> [!WARNING]\n> Be careful.")
		let title = attributed.runs.first
		#expect(title?.text == "Warning")
		#expect(title?.attributes.bold == true)
		#expect(title?.attributes.paragraph.kind == .alertTitle)
		#expect(title?.attributes.paragraph.alert == .warning)

		let body = run("Be careful.", in: attributed)
		#expect(body?.attributes.paragraph.alert == .warning)
	}

	@Test func githubAlertInlineBody() {
		let attributed = render("> [!NOTE] Inline body")
		#expect(attributed.runs.first?.text == "Note")
		#expect(run("Inline body", in: attributed)?.attributes.paragraph.alert == .note)
	}

	@Test func doccAsideAlert() {
		let attributed = render("> Tip: handy hint")
		#expect(attributed.runs.first?.text == "Tip")
		#expect(attributed.runs.first?.attributes.paragraph.alert == .tip)
		#expect(run("handy hint", in: attributed)?.attributes.paragraph.alert == .tip)
	}

	// MARK: Tables

	@Test func tableAttachmentCarriesCellsAndAlignment() {
		let markdown = """
		| Left | Right |
		|:-----|------:|
		| a    | b     |
		"""
		let attributed = render(markdown)
		guard case let .table(model)? = attributed.runs.first?.attributes.attachment else {
			Issue.record("expected a table attachment")
			return
		}
		#expect(model.alignments == [.left, .right])
		#expect(model.headers.map(\.string) == ["Left", "Right"])
		#expect(model.rows.count == 1)
		#expect(model.rows[0].map(\.string) == ["a", "b"])
		#expect(attributed.runs.first?.attributes.paragraph.kind == .table)
	}

	@Test func tableCellsPreserveInlineMarkup() {
		let markdown = """
		| H |
		|---|
		| **bold** |
		"""
		let attributed = render(markdown)
		guard case let .table(model)? = attributed.runs.first?.attributes.attachment else {
			Issue.record("expected a table attachment")
			return
		}
		#expect(model.rows[0][0].runs.first?.attributes.bold == true)
	}

	// MARK: Thematic break

	@Test func thematicBreakIsAHorizontalRuleAttachment() {
		let attributed = render("before\n\n---\n\nafter")
		let rule = attributed.runs.first { $0.attributes.attachment == .horizontalRule }
		#expect(rule != nil)
		#expect(rule?.attributes.paragraph.kind == .thematicBreak)
	}

	// MARK: Breaks

	@Test func softBreakBecomesSpace() {
		let attributed = render("line one\nline two")
		#expect(attributed.string == "line one line two")
	}

	@Test func hardBreakBecomesNewline() {
		let attributed = render("line one  \nline two")
		#expect(attributed.string == "line one\nline two")
	}

	// MARK: Raw HTML

	@Test func inlineHTMLIsLiteralText() {
		let attributed = render("a <span>b</span> c")
		#expect(attributed.string.contains("<span>"))
	}

	@Test func htmlBlockKind() {
		let attributed = render("<div>\nraw\n</div>")
		#expect(attributed.runs.first?.attributes.paragraph.kind == .htmlBlock)
		#expect(attributed.string.contains("<div>"))
	}

	// MARK: Footnotes

	@Test func footnoteReferenceIsSuperscript() {
		let attributed = render("Claim[^1].\n\n[^1]: Evidence.")
		let reference = attributed.runs.first { $0.attributes.footnoteReference != nil }
		#expect(reference?.attributes.footnoteReference == 1)
		#expect(reference?.attributes.baseline == .superscript)
		#expect(reference?.text == "1")
	}

	@Test func footnoteDefinitionBlockIsAppended() {
		let attributed = render("Claim[^1].\n\n[^1]: Evidence.")
		let label = attributed.runs.first { $0.text == "1. " }
		#expect(label?.attributes.bold == true)
		if case .footnoteDefinition = label?.attributes.paragraph.kind {} else {
			Issue.record("label should be a footnote definition paragraph")
		}
		let body = run("Evidence.", in: attributed)
		if case .footnoteDefinition = body?.attributes.paragraph.kind {} else {
			Issue.record("definition body should be a footnote definition paragraph")
		}
	}

	@Test func orphanFootnoteReferenceStaysLiteral() {
		// No matching definition -> the reference is left as literal text.
		let attributed = render("Claim[^missing].")
		#expect(attributed.runs.allSatisfy { $0.attributes.footnoteReference == nil })
		#expect(attributed.string.contains("[^missing]"))
	}

	// MARK: Smart punctuation

	@Test func smartPunctuationReversedByDefault() {
		let attributed = render("\"quoted\" and dashes---here")
		#expect(!attributed.string.contains("\u{201C}"))
		#expect(!attributed.string.contains("\u{2014}"))
		#expect(attributed.string.contains("\"quoted\""))
		#expect(attributed.string.contains("---"))
	}

	@Test func smartPunctuationPreservedWithOption() {
		let attributed = render("\"quoted\"", .preserveSmartPunctuation)
		#expect(attributed.string.contains("\u{201C}") || attributed.string.contains("\u{201D}"))
	}

	// MARK: Document entry point

	@Test func documentEntryPointSkipsFootnoteExtraction() {
		// convert(document:) does not run footnote extraction, so `[^1]:` stays literal.
		let document = Markdown.Document(parsing: "Body[^1].\n\n[^1]: note.")
		let attributed = MarkdownAttributedTextRenderer.convert(document: document)
		#expect(attributed.runs.allSatisfy { $0.attributes.footnoteReference == nil })
	}
}
