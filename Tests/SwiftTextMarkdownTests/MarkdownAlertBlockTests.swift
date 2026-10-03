import Markdown
import Testing

@testable import SwiftTextMarkdown

@Suite("Alert detection shared by every writer")
struct MarkdownAlertBlockTests {
	private func alert(_ markdown: String) -> MarkdownAlertBlock? {
		let document = Document(parsing: markdown)
		guard let quote = document.child(at: 0) as? BlockQuote else { return nil }
		return MarkdownAlertBlock.detect(in: quote)
	}

	private func bodyText(_ alert: MarkdownAlertBlock) -> String {
		alert.body.map { $0.format() }.joined(separator: "\n")
	}

	@Test("A GitHub alert: the kind's default title, body without the marker")
	func githubAlert() throws {
		let detected = try #require(alert("> [!NOTE]\n> Useful information."))
		#expect(detected.kind == "note")
		#expect(detected.title == "Note")
		#expect(!detected.hasCustomTitle)
		#expect(detected.syntax == .bracketed)
		#expect(bodyText(detected) == "Useful information.")
	}

	@Test("Text on the marker line is a custom title (Obsidian), not body")
	func customTitle() throws {
		let detected = try #require(alert("> [!WARNING] Watch out\n> A criminal at large."))
		#expect(detected.kind == "warning")
		#expect(detected.title == "Watch out")
		#expect(detected.hasCustomTitle)
		#expect(bodyText(detected) == "A criminal at large.")
		#expect(detected.markerLine == "[!WARNING] Watch out")
	}

	@Test("Any single-word kind is an alert, with a title from the kind and the neutral palette")
	func customKind() throws {
		let detected = try #require(alert("> [!EXAMPLE]\n> A letter might say:"))
		#expect(detected.kind == "example")
		#expect(detected.title == "Example")
		#expect(detected.palette == .neutral)
		#expect(MarkdownAlertBlock.defaultTitle(forKind: "watch-out") == "Watch out")
	}

	@Test("Multi-paragraph bodies, nested quotes and lists keep their blocks")
	func multiBlockBody() throws {
		let detected = try #require(alert("> [!TIP]\n> First.\n>\n> > Nested.\n>\n> - item"))
		#expect(detected.body.count == 3)
		#expect(detected.body[1] is BlockQuote)
		#expect(detected.body[2] is UnorderedList)
	}

	@Test("Obsidian fold markers are ignored; a title-only alert has no body")
	func foldMarkerAndTitleOnly() throws {
		let detected = try #require(alert("> [!note]- Folded title"))
		#expect(detected.kind == "note")
		#expect(detected.title == "Folded title")
		#expect(detected.body.isEmpty)
	}

	@Test("DocC asides: known kinds only, the rest of the line is body")
	func doccAside() throws {
		let detected = try #require(alert("> Warning: Mind the gap."))
		#expect(detected.kind == "warning")
		#expect(detected.syntax == .docc)
		#expect(bodyText(detected) == "Mind the gap.")
		#expect(alert("> Remember: this is an ordinary quote.") == nil)
	}

	@Test("Ordinary quotes and invalid markers are not alerts")
	func notAlerts() {
		#expect(alert("> Just a quote.") == nil)
		#expect(alert("> [!] empty kind") == nil)
		#expect(alert("> [!two words] not a kind") == nil)
		#expect(alert("> [link](https://example.com)") == nil)
	}

	@Test("The marker line omits a title that equals the kind's default")
	func markerLine() {
		#expect(MarkdownAlertBlock.markerLine(kind: "note", title: "Note") == "[!NOTE]")
		#expect(MarkdownAlertBlock.markerLine(kind: "note", title: nil) == "[!NOTE]")
		#expect(MarkdownAlertBlock.markerLine(kind: "warning", title: "Watch out") == "[!WARNING] Watch out")
	}

	@Test("The alert CSS is generated from the shared layout and palettes")
	func generatedCSS() {
		let css = MarkdownAlertLayout.css
		#expect(css.contains("margin: 0.8em 0;"))
		#expect(css.contains("padding: 0.75em 1em;"))
		#expect(css.contains("print-color-adjust: exact;"))
		#expect(css.contains(".markdown-alert-warning { background: #fff8c5; border-left-color: #9a6700; color: #7d4e00; }"))
	}
}
