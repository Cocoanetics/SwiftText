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
	private func synthesizedStyles(_ markdown: String) throws -> [String: TSWP_ParagraphStyleArchive] {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-callout-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToPages.convert(markdown, to: url)
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
		// title, body, end | separator | title, body, end
		#expect(laidOut.count == 7)
		#expect(laidOut[3].isSeparator)
		#expect(laidOut[3].callout == nil)
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

	@Test("Box spacing is the CSS em values times the body font size")
	func spacingFollowsTheFontSize() throws {
		let styles = try synthesizedStyles("Before.\n\n> [!TIP]\n> Body.\n\nAfter.\n")
		let em: Float = 11                                            // the template's Body size
		let end = try #require(styles["swifttext-callout-end:tip"]?.paraProperties)
		// The end paragraph carries the bottom padding and the bottom margin.
		#expect(abs((end.spaceBefore ?? 0) - (Float(MarkdownAlertLayout.paddingBlockEm) * em - PagesBoxLayout.hairlineLineHeight)) < 0.01)
		#expect(abs((end.spaceAfter ?? 0) - Float(MarkdownAlertLayout.marginEm + MarkdownAlertLayout.halfLeadingEm) * em) < 0.01)
		// The title's space before: the margin above (collapsing with Body's 8pt
		// space after) plus the top padding, drawn inside the fill.
		let title = try #require(styles["swifttext-callout-title:tip"]?.paraProperties)
		let margin = max(8, Float(MarkdownAlertLayout.marginEm) * em)
		#expect(abs((title.spaceBefore ?? 0) - (margin + Float(MarkdownAlertLayout.paddingBlockEm) * em)) < 0.01)
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
