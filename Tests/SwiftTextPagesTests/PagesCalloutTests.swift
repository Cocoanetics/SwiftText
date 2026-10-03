import Foundation
import Testing

@testable import SwiftTextPages
import SwiftTextIWA
import SwiftTextMarkdown

/// Alert boxes (`> [!NOTE]`), block quotes and horizontal rules: what Markdown → Pages
/// writes, that it reads back as the same Markdown, and that a box is spaced like the
/// CSS box in `em` of the body font size.
@Suite("Pages alert boxes, quotes and rules")
struct PagesCalloutTests {
	private func roundTrip(_ markdown: String) throws -> String {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-callout-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToPages.convert(markdown, to: url)
		return try PagesFile(url: url).markdown()
	}

	/// The paragraph-style objects the writer synthesized (in `Document.iwa`), keyed by
	/// their style identifier.
	private func synthesizedStyles(_ markdown: String, alertColors: MarkdownAlertColors = .builtIn) throws -> [String: TSWP_ParagraphStyleArchive] {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-callout-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToPages.convert(markdown, to: url, alertColors: alertColors)
		let document = try IWAContainer.entries(at: url, prefix: "Index/").first { $0.path.hasSuffix("Document.iwa") }
		var styles = [String: TSWP_ParagraphStyleArchive]()
		for object in try IWAArchive.objects(from: #require(document).data) where object.type == 2022 {
			let style = TSWP_ParagraphStyleArchive(ProtobufMessage(object.payload))
			if let identifier = style.super?.styleIdentifier { styles[identifier] = style }
		}
		return styles
	}

	@Test("An alert writes as a box and reads back as the same `> [!KIND]` block")
	func alertRoundTrips() throws {
		let markdown = """
		Before.

		> [!NOTE]
		> First paragraph.
		>
		> Second paragraph.

		After.
		"""
		#expect(try roundTrip(markdown) == markdown)
	}

	@Test("A custom title and a custom kind survive the round trip")
	func customTitleAndKind() throws {
		let markdown = """
		> [!WARNING] Watch out
		> A criminal who is *at large* has escaped.

		> [!EXAMPLE]
		> A letter might say:
		>
		> - first point
		> - second point
		"""
		#expect(try roundTrip(markdown) == markdown)
	}

	@Test("Two boxes of the same kind in a row stay two boxes, and read back as two")
	func adjacentBoxesOfOneKind() throws {
		let markdown = "> [!WARNING] First\n> One.\n\n> [!WARNING] Second\n> Two."
		#expect(try roundTrip(markdown) == markdown)
		let laidOut = PagesBoxLayout.apply(to: MarkdownToPages.paragraphs(markdown), fontSize: 11, baseSpacing: PagesWriter.baseSpacing(of:))
		// start, title, body, end | separator | start, title, body, end
		#expect(laidOut.count == 9)
		#expect(laidOut[4].isSeparator)
		#expect(laidOut[4].callout == nil)
	}

	@Test("Each kind gets a style variation named for it, in its palette")
	func kindVariations() throws {
		let styles = try synthesizedStyles("> [!CAUTION]\n> Careful.\n")
		let title = try #require(styles["swifttext-callout-title:caution"])
		let body = try #require(styles["swifttext-callout:caution"])
		#expect(styles["swifttext-callout-end:caution"] != nil)
		#expect(title.super?.isVariation == true)
		#expect(title.super?.parent?.identifier == PagesStyleID.calloutTitle)
		#expect(body.super?.parent?.identifier == PagesStyleID.calloutBody)
		// The caution palette (#FFEBE9 fill, #CF222E border), as in the CSS.
		let fill = try #require(body.paraProperties?.fill)
		#expect(abs((fill.r ?? 0) - Float(0xFF) / 255) < 0.01)
		#expect(abs((fill.g ?? 0) - Float(0xEB) / 255) < 0.01)
		#expect(body.paraProperties?.borderPositions == 4)          // the left edge
	}

	@Test("A stylesheet's alert colours replace the built-in palette")
	func colorsFromCSS() throws {
		let colors = MarkdownAlertColors(css: ".markdown-alert-careful { background: #f6f1ea; border-left-color: #b8975a; color: #3b3222; }")
		let styles = try synthesizedStyles("> [!CAREFUL] Watch out\n> Body.\n", alertColors: colors)
		let body = try #require(styles["swifttext-callout:careful"]?.paraProperties)
		let fill = try #require(body.fill)
		#expect(abs((fill.r ?? 0) - Float(0xF6) / 255) < 0.01)
		#expect(abs((fill.g ?? 0) - Float(0xF1) / 255) < 0.01)
		#expect(abs((fill.b ?? 0) - Float(0xEA) / 255) < 0.01)
	}

	@Test("Box spacing is the CSS em values times the body font size")
	func spacingFollowsTheFontSize() throws {
		let styles = try synthesizedStyles("Before.\n\n> [!TIP]\n> Body.\n\nAfter.\n")
		let em: Float = 11                                            // the template's Body size
		let end = try #require(styles["swifttext-callout-end:tip"]?.paraProperties)
		// The end paragraph carries the bottom padding and the bottom margin.
		#expect(abs((end.spaceBefore ?? 0) - (Float(MarkdownAlertLayout.paddingBlockEm) * em - PagesBoxLayout.hairlineLineHeight)) < 0.01)
		#expect(abs((end.spaceAfter ?? 0) - Float(MarkdownAlertLayout.marginEm + MarkdownAlertLayout.halfLeadingEm) * em) < 0.01)
		// The start paragraph carries the top: the margin above (collapsing with Body's
		// 8pt space after) as its space before, the top padding as its space after.
		let start = try #require(styles["swifttext-callout-start:tip"]?.paraProperties)
		let margin = max(8, Float(MarkdownAlertLayout.marginEm) * em)
		#expect(abs((start.spaceBefore ?? 0) - margin) < 0.01)
		#expect(abs((start.spaceAfter ?? 0) - (Float(MarkdownAlertLayout.paddingBlockEm) * em - PagesBoxLayout.hairlineLineHeight)) < 0.01)
		let title = try #require(styles["swifttext-callout-title:tip"]?.paraProperties)
		#expect((title.spaceBefore ?? 0) == 0)
	}

	@Test("The top padding is a start paragraph's space after, which Pages keeps at the top of a page")
	func topPaddingSurvivesAPageTop() {
		// Pages drops a paragraph's space before at the top of a page. Were the padding the
		// title's space before, a box opening a page would lose it.
		let laidOut = PagesBoxLayout.apply(to: MarkdownToPages.paragraphs("> [!WARNING] Watch out\n> Careful.\n"),
		                                   fontSize: 11, baseSpacing: PagesWriter.baseSpacing(of:))
		let roles = laidOut.compactMap { $0.callout?.role }
		#expect(roles == [.start, .title, .body, .end])
		let start = laidOut[0].callout
		#expect(start?.spaceBefore == 0)                       // nothing above at the document start
		#expect(abs((start?.spaceAfter ?? 0) - (Float(MarkdownAlertLayout.paddingBlockEm) * 11 - PagesBoxLayout.hairlineLineHeight)) < 0.01)
		#expect(start?.keepWithNext == true)
		#expect(laidOut[1].callout?.spaceBefore == 0)
	}

	@Test("Block quotes read back as quotes, not italic paragraphs (#109)")
	func blockQuoteRoundTrips() throws {
		let markdown = """
		> A quoted paragraph.
		>
		> A second one, with **bold**.

		After.
		"""
		#expect(try roundTrip(markdown) == markdown)
	}

	@Test("A thematic break is a native rule paragraph and reads back as `---` (#110)")
	func ruleRoundTrips() throws {
		let markdown = "Above.\n\n---\n\nBelow."
		#expect(try roundTrip(markdown) == markdown)
		let paragraphs = MarkdownToPages.paragraphs(markdown)
		let rules = paragraphs.filter { $0.isRule }
		#expect(rules.count == 1)
		#expect(rules.first?.text.isEmpty == true)
		#expect(rules.first?.paragraphStyle == PagesStyleID.rule)
		let boxDrawing = paragraphs.contains { $0.text.contains("\u{2500}") }
		#expect(!boxDrawing)
	}

	@Test("Inside a box, quotes become italic lines, headings bold lines and code monospace ones, keeping one frame")
	func nestedBlocksStayInTheBox() throws {
		let paragraphs = MarkdownToPages.paragraphs("> [!NOTE]\n> ## Heading\n>\n> > “Example.”\n>\n> ```\n> a\n>   b\n> ```\n")
		try #require(paragraphs.count == 4)
		let allNote = paragraphs.allSatisfy { $0.callout?.kind == "note" }
		let headingBold = paragraphs[1].runs.allSatisfy { $0.style.bold }
		let quoteItalic = paragraphs[2].runs.allSatisfy { $0.style.italic }
		let codeMonospace = paragraphs[3].runs.count == 1 && paragraphs[3].runs.allSatisfy { $0.style.code }
		let anyQuoteStyle = paragraphs.contains { $0.blockQuote }
		let anyCodeStyle = paragraphs.contains { $0.paragraphStyle == PagesStyleID.codeBlock }
		#expect(allNote)
		#expect(headingBold)
		#expect(quoteItalic)
		#expect(codeMonospace)
		#expect(paragraphs[3].text == "a\u{2028}  b")
		#expect(!anyQuoteStyle)
		#expect(!anyCodeStyle)
	}
}
