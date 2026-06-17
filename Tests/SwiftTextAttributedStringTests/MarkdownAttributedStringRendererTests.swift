import Testing
import Foundation
import Markdown
@testable import SwiftTextAttributedString

/// Verifies the renderer produces a Foundation `AttributedString` whose
/// `presentationIntent` / `inlinePresentationIntent` structure matches what
/// Foundation's own Markdown parser emits, plus the custom-scope attributes for
/// features Foundation can't express (footnotes, alerts, image source).
@Suite("MarkdownAttributedStringRenderer")
struct MarkdownAttributedStringRendererTests {

	// MARK: Helpers

	private func render(
		_ markdown: String, _ options: MarkdownAttributedStringRenderer.Options = []
	) -> AttributedString {
		MarkdownAttributedStringRenderer.convert(markdown, options: options)
	}

	private func wholeString(_ attributed: AttributedString) -> String {
		String(attributed.characters[attributed.startIndex..<attributed.endIndex])
	}

	private func firstRun(
		_ attributed: AttributedString, where predicate: (String) -> Bool
	) -> AttributedString.Runs.Element? {
		for run in attributed.runs where predicate(String(attributed.characters[run.range])) {
			return run
		}
		return nil
	}

	private func blockKinds(_ run: AttributedString.Runs.Element?) -> [String] {
		(run?.presentationIntent?.components ?? []).map { "\($0.kind)" }
	}

	// MARK: Blocks

	@Test func headingIsHeaderIntent() {
		let attributed = render("# Title")
		#expect(wholeString(attributed) == "Title")
		#expect(blockKinds(attributed.runs.first) == ["header 1"])
	}

	@Test func paragraphsGetDistinctIdentitiesNoNewline() {
		let attributed = render("alpha\n\nbeta")
		// Foundation separates blocks by intent identity, not literal newlines.
		#expect(wholeString(attributed) == "alphabeta")
		let ids = attributed.runs.compactMap { $0.presentationIntent?.components.first?.identity }
		#expect(ids.count == 2)
		#expect(ids[0] != ids[1])
		#expect(attributed.runs.allSatisfy { blockKinds($0) == ["paragraph"] })
	}

	// MARK: Inline intents

	@Test func emphasisStrongCodeStrikethrough() {
		let attributed = render("a **b** _c_ `d` ~~e~~")
		#expect(firstRun(attributed) { $0 == "b" }?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
		#expect(firstRun(attributed) { $0 == "c" }?.inlinePresentationIntent?.contains(.emphasized) == true)
		#expect(firstRun(attributed) { $0 == "d" }?.inlinePresentationIntent?.contains(.code) == true)
		#expect(firstRun(attributed) { $0 == "e" }?.inlinePresentationIntent?.contains(.strikethrough) == true)
	}

	@Test func linkUsesFoundationLinkAttribute() {
		let attributed = render("[home](https://example.com)")
		#expect(firstRun(attributed) { $0 == "home" }?.link == URL(string: "https://example.com"))
	}

	@Test func autolink() {
		let attributed = render("<https://example.com>")
		#expect(attributed.runs.first?.link == URL(string: "https://example.com"))
	}

	// MARK: Lists

	@Test func unorderedListIntentChainAndSharedListIdentity() {
		let attributed = render("- one\n- two")
		let one = firstRun(attributed) { $0 == "one" }
		let two = firstRun(attributed) { $0 == "two" }
		#expect(blockKinds(one) == ["paragraph", "listItem 1", "unorderedList"])
		#expect(blockKinds(two) == ["paragraph", "listItem 2", "unorderedList"])
		// Sibling items must share ONE unorderedList identity to be one list.
		#expect(one?.presentationIntent?.components.last?.identity == two?.presentationIntent?.components.last?.identity)
	}

	@Test func orderedListRespectsStartIndex() {
		let attributed = render("3. three\n4. four")
		#expect(blockKinds(firstRun(attributed) { $0 == "three" }) == ["paragraph", "listItem 3", "orderedList"])
		#expect(blockKinds(firstRun(attributed) { $0 == "four" }) == ["paragraph", "listItem 4", "orderedList"])
	}

	@Test func nestedListChainsParents() {
		let attributed = render("- outer\n  - inner")
		#expect(blockKinds(firstRun(attributed) { $0 == "inner" })
			== ["paragraph", "listItem 1", "unorderedList", "listItem 1", "unorderedList"])
	}

	@Test func taskListItemsRender() {
		let attributed = render("- [x] done\n- [ ] todo")
		// Foundation has no checkbox intent; task items render as list items.
		#expect(firstRun(attributed) { $0.contains("done") } != nil)
		#expect(firstRun(attributed) { $0.contains("todo") } != nil)
	}

	// MARK: Blockquote, code, rule

	@Test func blockquoteIntent() {
		let attributed = render("> quoted")
		#expect(blockKinds(firstRun(attributed) { $0 == "quoted" }) == ["paragraph", "blockQuote"])
	}

	@Test func codeBlockKeepsLanguageAndTrailingNewline() {
		let attributed = render("```swift\nlet x = 1\n```")
		let run = attributed.runs.first
		#expect(String(attributed.characters[run!.range]) == "let x = 1\n")
		#expect(blockKinds(run) == ["codeBlock \'swift\'"])
	}

	@Test func thematicBreakUsesFoundationPlaceholder() {
		let attributed = render("a\n\n---\n\nb")
		let rule = firstRun(attributed) { $0 == "\u{2E3B}" }
		#expect(rule != nil)
		#expect(blockKinds(rule) == ["thematicBreak"])
	}

	// MARK: Breaks

	@Test func softBreakIsSpaceWithIntent() {
		let attributed = render("line one\nline two")
		#expect(wholeString(attributed) == "line one line two")
		#expect(firstRun(attributed) { $0 == " " }?.inlinePresentationIntent?.contains(.softBreak) == true)
	}

	@Test func hardBreakIsNewlineWithIntent() {
		let attributed = render("line one  \nline two")
		#expect(wholeString(attributed) == "line one\nline two")
		#expect(firstRun(attributed) { $0 == "\n" }?.inlinePresentationIntent?.contains(.lineBreak) == true)
	}

	// MARK: HTML

	@Test func inlineHTMLIntent() {
		let attributed = render("a <b>x</b>")
		#expect(firstRun(attributed) { $0 == "<b>" }?.inlinePresentationIntent?.contains(.inlineHTML) == true)
	}

	@Test func htmlBlockHasNoPresentationIntent() {
		let attributed = render("<div>raw</div>")
		let run = attributed.runs.first
		#expect(run?.presentationIntent == nil)
		#expect(run?.inlinePresentationIntent?.contains(.blockHTML) == true)
	}

	// MARK: Tables

	@Test func tableIntentStructureAndAlignment() {
		let markdown = """
		| Left | Right |
		|:-----|------:|
		| a    | b     |
		"""
		let attributed = render(markdown)
		let headerCell = firstRun(attributed) { $0 == "Left" }
		#expect(blockKinds(headerCell).contains("tableHeaderRow"))
		#expect(blockKinds(headerCell).first == "tableCell 0")

		let bodyCell = firstRun(attributed) { $0 == "b" }
		let kinds = blockKinds(bodyCell)
		#expect(kinds.count == 3)
		#expect(kinds[0] == "tableCell 1")
		#expect(kinds[1] == "tableRow 1")
		#expect(kinds[2].hasPrefix("table"))

		// Column alignments are carried on the outermost `table` intent.
		guard case let .table(columns)? = bodyCell?.presentationIntent?.components.last?.kind else {
			Issue.record("missing table intent"); return
		}
		#expect(columns.map(\.alignment) == [.left, .right])
	}

	// MARK: Footnotes (custom scope)

	@Test func footnoteReferenceCarriesNumber() {
		let attributed = render("Claim[^1].\n\n[^1]: Evidence.")
		let reference = attributed.runs.first { $0[SwiftTextMarkdownAttributes.FootnoteReference.self] != nil }
		#expect(reference?[SwiftTextMarkdownAttributes.FootnoteReference.self] == 1)
		#expect(reference.map { String(attributed.characters[$0.range]) } == "1")
	}

	@Test func footnoteDefinitionBlockAppended() {
		let attributed = render("Claim[^1].\n\n[^1]: Evidence.")
		let label = firstRun(attributed) { $0 == "1. " }
		#expect(label?[SwiftTextMarkdownAttributes.FootnoteDefinition.self] == 1)
		#expect(label?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
		let body = firstRun(attributed) { $0 == "Evidence." }
		#expect(body?[SwiftTextMarkdownAttributes.FootnoteDefinition.self] == 1)
	}

	@Test func orphanFootnoteStaysLiteral() {
		let attributed = render("Claim[^missing].")
		#expect(attributed.runs.allSatisfy { $0[SwiftTextMarkdownAttributes.FootnoteReference.self] == nil })
		#expect(wholeString(attributed).contains("[^missing]"))
	}

	@Test func footnoteAndBodyIntentIdentitiesDoNotCollide() {
		let attributed = render("a[^1] b[^2]\n\n[^1]: one\n\n[^2]: two")
		// Leaf paragraph identities used by footnote-definition runs must be
		// disjoint from those used by body runs — proving the shared counter
		// never reissues an identity across the body/footnote boundary.
		var definitionIDs = Set<Int>()
		var bodyIDs = Set<Int>()
		for run in attributed.runs {
			guard let identity = run.presentationIntent?.components.first?.identity else { continue }
			if run[SwiftTextMarkdownAttributes.FootnoteDefinition.self] != nil {
				definitionIDs.insert(identity)
			} else {
				bodyIDs.insert(identity)
			}
		}
		#expect(!definitionIDs.isEmpty)
		#expect(!bodyIDs.isEmpty)
		#expect(definitionIDs.isDisjoint(with: bodyIDs))
	}

	// MARK: Alerts (custom scope)

	@Test func githubAlertTaggedAndMarkerStripped() {
		let attributed = render("> [!WARNING]\n> Be careful.")
		let body = firstRun(attributed) { $0.contains("Be careful.") }
		#expect(body?[SwiftTextMarkdownAttributes.Alert.self] == .warning)
		// Marker is stripped (unlike Foundation, which keeps literal [!WARNING]).
		#expect(!wholeString(attributed).contains("[!WARNING]"))
		#expect(blockKinds(body) == ["paragraph", "blockQuote"])
	}

	@Test func doccAsideTagged() {
		let attributed = render("> Tip: handy")
		let body = firstRun(attributed) { $0.contains("handy") }
		#expect(body?[SwiftTextMarkdownAttributes.Alert.self] == .tip)
	}

	// MARK: Images (custom scope)

	@Test func imageKeepsAltTextAndSource() {
		let attributed = render("![A diagram](diagram.png)")
		let run = attributed.runs.first
		#expect(run.map { String(attributed.characters[$0.range]) } == "A diagram")
		#expect(run?[SwiftTextMarkdownAttributes.ImageSource.self] == "diagram.png")
	}

	// MARK: Smart punctuation

	@Test func smartPunctuationReversedByDefault() {
		let attributed = render("\"q\" a---b")
		let string = wholeString(attributed)
		#expect(!string.contains("\u{201C}"))
		#expect(!string.contains("\u{2014}"))
		#expect(string.contains("\"q\""))
		#expect(string.contains("---"))
	}

	@Test func smartPunctuationPreservedWithOption() {
		let attributed = render("\"q\"", .preserveSmartPunctuation)
		let string = wholeString(attributed)
		#expect(string.contains("\u{201C}") || string.contains("\u{201D}"))
	}

	// MARK: Entry points

	@Test func convenienceInitializer() {
		let attributed = AttributedString(swiftTextMarkdown: "# Hi")
		#expect(blockKinds(attributed.runs.first) == ["header 1"])
	}

	@Test func documentEntryPointSkipsFootnotes() {
		let document = Document(parsing: "Body[^1].\n\n[^1]: note.")
		let attributed = MarkdownAttributedStringRenderer.convert(document: document)
		#expect(attributed.runs.allSatisfy { $0[SwiftTextMarkdownAttributes.FootnoteReference.self] == nil })
	}
}
