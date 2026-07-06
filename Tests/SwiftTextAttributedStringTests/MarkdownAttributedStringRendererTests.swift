// `AttributedString` needs iOS 15 / tvOS 15 / watchOS 8, but the package deploys
// those platforms lower (13/13/6) for its other modules, and swift-testing's
// @Suite/@Test macros reject an `@available` annotation. So compile these tests
// only where the deployment target already has `AttributedString`: macOS (.v12)
// and non-Apple platforms (swift-foundation, unconditional). The renderer logic
// is platform-independent, so macOS + Linux coverage exercises every path.
#if os(macOS) || !canImport(Darwin)

import Testing
import Foundation
import Markdown
@testable import SwiftTextAttributedString

/// Cross-platform coverage: asserts on the portable custom attributes
/// (``MarkdownBlock`` / ``MarkdownInlineStyle`` / footnotes / alerts / image
/// source) that the renderer sets on every platform. Native-intent interop is
/// covered separately (Apple-only) in `NativeIntentBridgeTests`.
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

	private func kinds(_ run: AttributedString.Runs.Element?) -> [MarkdownBlock.Kind] {
		(run?[SwiftTextMarkdownAttributes.Block.self]?.components ?? []).map(\.kind)
	}

	private func style(_ run: AttributedString.Runs.Element?) -> MarkdownInlineStyle {
		run?[SwiftTextMarkdownAttributes.InlineStyle.self] ?? []
	}

	// MARK: Blocks

	@Test func headingIsHeaderBlock() {
		let attributed = render("# Title")
		#expect(wholeString(attributed) == "Title")
		#expect(kinds(attributed.runs.first) == [.header(level: 1)])
	}

	@Test func headingLevelsOneThroughSix() {
		for level in 1...6 {
			let attributed = render(String(repeating: "#", count: level) + " H")
			#expect(kinds(attributed.runs.first) == [.header(level: level)])
		}
	}

	@Test func paragraphsGetDistinctIdentitiesNoNewline() {
		let attributed = render("alpha\n\nbeta")
		// Blocks are separated by intent identity, not literal newlines.
		#expect(wholeString(attributed) == "alphabeta")
		let ids = attributed.runs.compactMap {
			$0[SwiftTextMarkdownAttributes.Block.self]?.components.first?.identity
		}
		#expect(ids.count == 2)
		#expect(ids[0] != ids[1])
		#expect(attributed.runs.allSatisfy { kinds($0) == [.paragraph] })
	}

	// MARK: Inline styles

	@Test func emphasisStrongCodeStrikethrough() {
		let attributed = render("a **b** _c_ `d` ~~e~~")
		#expect(style(firstRun(attributed) { $0 == "b" }).contains(.stronglyEmphasized))
		#expect(style(firstRun(attributed) { $0 == "c" }).contains(.emphasized))
		#expect(style(firstRun(attributed) { $0 == "d" }).contains(.code))
		#expect(style(firstRun(attributed) { $0 == "e" }).contains(.strikethrough))
	}

	@Test func nestedEmphasisCombines() {
		let attributed = render("***both***")
		let run = firstRun(attributed) { $0 == "both" }
		#expect(style(run).contains(.emphasized))
		#expect(style(run).contains(.stronglyEmphasized))
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

	@Test func unorderedListChainAndSharedListIdentity() {
		let attributed = render("- one\n- two")
		let one = firstRun(attributed) { $0 == "one" }
		let two = firstRun(attributed) { $0 == "two" }
		#expect(kinds(one) == [.paragraph, .listItem(ordinal: 1), .unorderedList])
		#expect(kinds(two) == [.paragraph, .listItem(ordinal: 2), .unorderedList])
		// Siblings must share ONE unorderedList identity to be one list.
		let oneList = one?[SwiftTextMarkdownAttributes.Block.self]?.components.last?.identity
		let twoList = two?[SwiftTextMarkdownAttributes.Block.self]?.components.last?.identity
		#expect(oneList == twoList)
	}

	@Test func orderedListRespectsStartIndex() {
		let attributed = render("3. three\n4. four")
		#expect(kinds(firstRun(attributed) { $0 == "three" }) == [.paragraph, .listItem(ordinal: 3), .orderedList])
		#expect(kinds(firstRun(attributed) { $0 == "four" }) == [.paragraph, .listItem(ordinal: 4), .orderedList])
	}

	@Test func nestedListChainsParents() {
		let attributed = render("- outer\n  - inner")
		#expect(kinds(firstRun(attributed) { $0 == "inner" })
			== [.paragraph, .listItem(ordinal: 1), .unorderedList, .listItem(ordinal: 1), .unorderedList])
	}

	@Test func taskListCheckboxState() {
		let attributed = render("- [x] done\n- [ ] todo")
		let done = firstRun(attributed) { $0.contains("done") }
		let todo = firstRun(attributed) { $0.contains("todo") }
		#expect(done?[SwiftTextMarkdownAttributes.Checkbox.self] == .checked)
		#expect(todo?[SwiftTextMarkdownAttributes.Checkbox.self] == .unchecked)
		#expect(kinds(done).contains(.unorderedList))
	}

	@Test func plainListItemHasNoCheckbox() {
		let attributed = render("- plain")
		#expect(firstRun(attributed) { $0 == "plain" }?[SwiftTextMarkdownAttributes.Checkbox.self] == nil)
	}

	@Test func nestedListCheckboxDoesNotLeak() {
		// A checked parent must not stamp its checkbox onto a plain nested item.
		let attributed = render("- [x] parent\n  - child")
		#expect(firstRun(attributed) { $0 == "parent" }?[SwiftTextMarkdownAttributes.Checkbox.self] == .checked)
		#expect(firstRun(attributed) { $0 == "child" }?[SwiftTextMarkdownAttributes.Checkbox.self] == nil)
	}

	// MARK: Blockquote, code, rule

	@Test func blockquoteChain() {
		let attributed = render("> quoted")
		#expect(kinds(firstRun(attributed) { $0 == "quoted" }) == [.paragraph, .blockQuote])
	}

	@Test func codeBlockKeepsLanguageAndTrailingNewline() {
		let attributed = render("```swift\nlet x = 1\n```")
		let run = attributed.runs.first
		#expect(String(attributed.characters[run!.range]) == "let x = 1\n")
		#expect(kinds(run) == [.codeBlock(languageHint: "swift")])
	}

	@Test func indentedCodeBlockHasNilLanguage() {
		let attributed = render("    indented")
		#expect(kinds(attributed.runs.first) == [.codeBlock(languageHint: nil)])
	}

	@Test func thematicBreakUsesPlaceholder() {
		let attributed = render("a\n\n---\n\nb")
		let rule = firstRun(attributed) { $0 == "\u{2E3B}" }
		#expect(kinds(rule) == [.thematicBreak])
	}

	// MARK: Breaks

	@Test func softBreakIsSpaceWithStyle() {
		let attributed = render("line one\nline two")
		#expect(wholeString(attributed) == "line one line two")
		#expect(style(firstRun(attributed) { $0 == " " }).contains(.softBreak))
	}

	@Test func hardBreakIsNewlineWithStyle() {
		let attributed = render("line one  \nline two")
		#expect(wholeString(attributed) == "line one\nline two")
		#expect(style(firstRun(attributed) { $0 == "\n" }).contains(.lineBreak))
	}

	// MARK: HTML

	@Test func inlineHTMLStyle() {
		let attributed = render("a <b>x</b>")
		#expect(style(firstRun(attributed) { $0 == "<b>" }).contains(.inlineHTML))
	}

	@Test func htmlBlockHasNoBlockButBlockHTMLStyle() {
		let attributed = render("<div>raw</div>")
		let run = attributed.runs.first
		#expect(run?[SwiftTextMarkdownAttributes.Block.self] == nil)
		#expect(style(run).contains(.blockHTML))
	}

	// MARK: Tables

	@Test func tableChainAndAlignment() {
		let markdown = """
		| Left | Right |
		|:-----|------:|
		| a    | b     |
		"""
		let attributed = render(markdown)
		let headerCell = firstRun(attributed) { $0 == "Left" }
		#expect(kinds(headerCell).first == .tableCell(columnIndex: 0))
		#expect(kinds(headerCell).contains(.tableHeaderRow))

		let bodyCell = firstRun(attributed) { $0 == "b" }
		let bodyKinds = kinds(bodyCell)
		#expect(bodyKinds.count == 3)
		#expect(bodyKinds[0] == .tableCell(columnIndex: 1))
		#expect(bodyKinds[1] == .tableRow(rowIndex: 1))
		#expect(bodyKinds[2] == .table(columns: [.left, .right]))
	}

	// MARK: Footnotes

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
		#expect(style(label).contains(.stronglyEmphasized))
		let body = firstRun(attributed) { $0 == "Evidence." }
		#expect(body?[SwiftTextMarkdownAttributes.FootnoteDefinition.self] == 1)
	}

	@Test func orphanFootnoteStaysLiteral() {
		let attributed = render("Claim[^missing].")
		#expect(attributed.runs.allSatisfy { $0[SwiftTextMarkdownAttributes.FootnoteReference.self] == nil })
		#expect(wholeString(attributed).contains("[^missing]"))
	}

	@Test func nestedFootnoteDefinitionResolves() {
		// `[^b]` is referenced only inside `[^a]`'s body — its definition must
		// still be emitted (not orphaned) and its reference numbered.
		let attributed = render("Main[^a]\n\n[^a]: see [^b]\n\n[^b]: other")
		let definitionNumbers = Set(attributed.runs.compactMap {
			$0[SwiftTextMarkdownAttributes.FootnoteDefinition.self]
		})
		#expect(definitionNumbers == [1, 2])
		let referenceNumbers = Set(attributed.runs.compactMap {
			$0[SwiftTextMarkdownAttributes.FootnoteReference.self]
		})
		#expect(referenceNumbers.contains(2))
		#expect(wholeString(attributed).contains("other"))
	}

	@Test func footnoteAndBodyIdentitiesDoNotCollide() {
		let attributed = render("a[^1] b[^2]\n\n[^1]: one\n\n[^2]: two")
		var definitionIDs = Set<Int>()
		var bodyIDs = Set<Int>()
		for run in attributed.runs {
			guard let identity = run[SwiftTextMarkdownAttributes.Block.self]?.components.first?.identity else { continue }
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

	// MARK: Alerts

	@Test func githubAlertTaggedAndMarkerStripped() {
		let attributed = render("> [!WARNING]\n> Be careful.")
		let body = firstRun(attributed) { $0.contains("Be careful.") }
		#expect(body?[SwiftTextMarkdownAttributes.Alert.self] == .warning)
		#expect(!wholeString(attributed).contains("[!WARNING]"))
		#expect(kinds(body) == [.paragraph, .blockQuote])
	}

	@Test func doccAsideTagged() {
		let attributed = render("> Tip: handy")
		#expect(firstRun(attributed) { $0.contains("handy") }?[SwiftTextMarkdownAttributes.Alert.self] == .tip)
	}

	// MARK: Images

	@Test func imageKeepsAltTextAndSource() {
		let attributed = render("![A diagram](diagram.png)")
		let run = attributed.runs.first
		#expect(run.map { String(attributed.characters[$0.range]) } == "A diagram")
		#expect(run?[SwiftTextMarkdownAttributes.ImageSource.self] == "diagram.png")
	}

	// MARK: Smart punctuation

	@Test func smartPunctuationNotAppliedByDefault() {
		let string = wholeString(render("\"q\" a---b"))
		#expect(!string.contains("\u{201C}"))
		#expect(!string.contains("\u{2014}"))
		#expect(string.contains("\"q\""))
		#expect(string.contains("---"))
	}

	@Test func smartPunctuationPreservedWithOption() {
		let string = wholeString(render("\"q\"", .preserveSmartPunctuation))
		#expect(string.contains("\u{201C}") || string.contains("\u{201D}"))
	}

	@Test func literalTypographicCharactersSurviveByDefault() {
		// Real Unicode em/en dashes, ellipsis, and curly quotes already present in
		// the source must not be mangled into their ASCII spellings (issue #38).
		let string = wholeString(render("a — b – c… “quoted” ‘single’"))
		#expect(string == "a — b – c… “quoted” ‘single’")
	}

	// MARK: Entry points

	@Test func convenienceInitializer() {
		let attributed = AttributedString(swiftTextMarkdown: "# Hi")
		#expect(kinds(attributed.runs.first) == [.header(level: 1)])
	}

	@Test func documentEntryPointSkipsFootnotes() {
		let document = Document(parsing: "Body[^1].\n\n[^1]: note.")
		let attributed = MarkdownAttributedStringRenderer.convert(document: document)
		#expect(attributed.runs.allSatisfy { $0[SwiftTextMarkdownAttributes.FootnoteReference.self] == nil })
	}
}

#endif
