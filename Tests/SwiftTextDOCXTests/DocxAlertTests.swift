import Foundation
import Testing

@testable import SwiftTextDOCX
import SwiftTextMarkdown

/// Alert boxes (`> [!NOTE]`) and horizontal rules: what Markdown → DOCX writes, that it
/// reads back as the same Markdown, and that a box is spaced like the CSS box in `em`
/// of the body font size.
@Suite("DOCX alert boxes and rules")
struct DocxAlertTests {
	private struct Written {
		var document: String
		var styles: String

		/// The body paragraphs (`<w:p>…</w:p>`), in order.
		var paragraphs: [String] {
			document.components(separatedBy: "<w:p>").dropFirst().map { $0.components(separatedBy: "</w:p>")[0] }
		}

		/// The paragraphs in a callout style of `kind`.
		func callout(_ kind: String) -> [String] {
			paragraphs.filter { $0.contains("\"SwiftTextCallout-\(kind)\"") || $0.contains("\"SwiftTextCalloutTitle-\(kind)\"") }
		}
	}

	private func write(_ markdown: String) throws -> Written {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-alert-\(UUID().uuidString).docx")
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToDocx.convert(markdown, to: url)
		let archive = try DocxArchive(contentsOf: url)
		return Written(document: try archive.text("word/document.xml"), styles: try archive.text("word/styles.xml"))
	}

	private func roundTrip(_ markdown: String) throws -> String {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-alert-\(UUID().uuidString).docx")
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToDocx.convert(markdown, to: url)
		return try DocxFile(url: url).markdown()
	}

	/// The integer value of `attribute` in the first `element` of `xml`.
	private func value(_ attribute: String, of element: String, in xml: String) -> Int? {
		guard let start = xml.range(of: "<\(element) ") else { return nil }
		let tag = xml[start.upperBound...].prefix { $0 != ">" }
		guard let found = tag.range(of: "\(attribute)=\"") else { return nil }
		return Int(tag[found.upperBound...].prefix { $0 != "\"" })
	}

	private var layout: DocxBoxLayout { DocxBoxLayout(fontSize: DocxWriter.bodyFontSize) }
	private func twips(_ em: Double) -> Int { Int((em * DocxWriter.bodyFontSize * 20).rounded()) }

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
		let written = try write(markdown)
		#expect(written.callout("note").count == 3)                  // title + two paragraphs
		#expect(!written.document.contains("[!NOTE]"))
	}

	@Test("A custom title and a custom kind survive the round trip, lists included")
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

	@Test("Two boxes in a row stay two boxes: an unbordered spacer parts them")
	func adjacentBoxes() throws {
		let markdown = "> [!WARNING] First\n> One.\n\n> [!WARNING] Second\n> Two."
		#expect(try roundTrip(markdown) == markdown)
		let paragraphs = try write(markdown).paragraphs
		// title, body | spacer | title, body
		#expect(paragraphs.count == 5)
		if paragraphs.count == 5 {
			#expect(!paragraphs[2].contains("pStyle"))
			#expect(!paragraphs[2].contains("pBdr"))
			#expect(paragraphs[2].contains("w:lineRule=\"exact\""))
			// The gap between the boxes is the CSS margin: the first box's space after
			// plus the spacer's line; the second title adds nothing.
			let after = value("w:after", of: "w:spacing", in: paragraphs[1])
			#expect(after == layout.margin - DocxBoxLayout.hairlineTwips)
			#expect(value("w:before", of: "w:spacing", in: paragraphs[3]) == 0)
		}
	}

	@Test("Each kind gets a style pair in its palette; the title inherits the frame")
	func kindStyles() throws {
		let styles = try write("> [!CAUTION]\n> Careful.\n").styles
		let body = try #require(styles.components(separatedBy: "w:styleId=\"SwiftTextCallout-caution\"").dropFirst().first?
			.components(separatedBy: "</w:style>").first)
		let title = try #require(styles.components(separatedBy: "w:styleId=\"SwiftTextCalloutTitle-caution\"").dropFirst().first?
			.components(separatedBy: "</w:style>").first)
		#expect(body.contains("<w:name w:val=\"Callout Caution\"/>"))
		#expect(title.contains("<w:name w:val=\"Callout Caution Title\"/>"))
		#expect(title.contains("<w:basedOn w:val=\"SwiftTextCallout-caution\"/>"))
		#expect(!title.contains("<w:pBdr>"))                          // the frame is inherited
		// The caution palette (#FFEBE9 fill, #CF222E border, #A40E26 text), as in the CSS.
		#expect(body.contains("<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"FFEBE9\"/>"))
		#expect(body.contains("<w:left w:val=\"single\" w:sz=\"24\" w:space=\"11\" w:color=\"CF222E\"/>"))
		#expect(body.contains("<w:color w:val=\"A40E26\"/>"))
		// The indents put the box's outer edges on the text column: padding + border.
		#expect(value("w:left", of: "w:ind", in: body) == (11 + 3) * 20)
		#expect(value("w:right", of: "w:ind", in: body) == layout.rightIndent)
	}

	@Test("A stylesheet's alert colours replace the built-in palette")
	func colorsFromCSS() throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("swifttext-alert-\(UUID().uuidString).docx")
		defer { try? FileManager.default.removeItem(at: url) }
		let colors = MarkdownAlertColors(css: ".markdown-alert-careful { background: rgba(184, 151, 90, 0.13); border-left: 3pt solid #b8975a; color: #3b3222; }")
		try MarkdownToDocx.convert("> [!CAREFUL] Watch out\n> Body.\n", to: url, alertColors: colors)
		let styles = try DocxArchive(contentsOf: url).text("word/styles.xml")
		#expect(styles.contains("<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F6F1EA\"/>"))
		#expect(styles.contains("w:color=\"B8975A\"/>"))
		#expect(styles.contains("<w:color w:val=\"3B3222\"/>"))
	}

	@Test("Box spacing is the CSS em values times the body font size, net of the neighbours' own")
	func spacingFollowsTheFontSize() throws {
		let box = try write("Before.\n\n> [!TIP]\n> Body.\n\n## After\n\nText.\n").callout("tip")
		try #require(box.count == 2)
		let margin = twips(MarkdownAlertLayout.marginEm)
		// Above: the margin, less Normal's space after (Word adds the two, CSS collapses).
		#expect(value("w:before", of: "w:spacing", in: box[0]) == margin - DocxWriter.paragraphSpaceAfter)
		#expect(value("w:after", of: "w:spacing", in: box[0]) == twips(MarkdownAlertLayout.paragraphMarginEm))
		// Below: the margin, less the heading's own space before, plus the half-leading.
		let headingBefore = DocxWriter.headingSpaceBefore(level: 2)
		#expect(value("w:after", of: "w:spacing", in: box[1]) == max(0, margin - headingBefore) + twips(MarkdownAlertLayout.halfLeadingEm))
		// Padding: the top and bottom borders' space, in whole points of 0.75em.
		let styles = try write("> [!TIP]\n> Body.\n").styles
		#expect(styles.contains("<w:top w:val=\"single\" w:sz=\"4\" w:space=\"\(Int((MarkdownAlertLayout.paddingBlockEm * DocxWriter.bodyFontSize).rounded()))\""))
	}

	@Test("A box with a list keeps one frame: every paragraph shares the indent, bullets hang in the padding")
	func listsKeepOneFrame() throws {
		let box = try write("> [!NOTE]\n> Intro.\n>\n> - one\n> - two\n>   - nested\n>\n> Outro.\n").callout("note")
		try #require(box.count == 6)
		let lefts = Set(box.map { value("w:left", of: "w:ind", in: $0) })
		let rights = Set(box.map { value("w:right", of: "w:ind", in: $0) })
		let borders = Set(box.map { $0.components(separatedBy: "<w:pBdr>").dropFirst().first?.components(separatedBy: "</w:pBdr>").first })
		#expect(lefts == [layout.leftIndent(listHang: DocxWriter.listHangingIndent, offset: 0)])
		#expect(rights == [layout.rightIndent])
		#expect(borders.count == 1)
		#expect(box[2].contains("w:hanging=\"\(DocxWriter.listHangingIndent)\""))
		#expect(box[4].contains("<w:ilvl w:val=\"1\"/>"))               // the nesting level survives
		// Between list items: the CSS li margin.
		#expect(value("w:after", of: "w:spacing", in: box[2]) == twips(MarkdownAlertLayout.listItemMarginEm))
	}

	@Test("Inside a box, headings become bold lines, quotes italic ones and code monospace ones")
	func nestedBlocksStayInTheBox() throws {
		let written = try write("> [!NOTE]\n> ## Heading\n>\n> > Quoted.\n>\n> ```\n> a\n>   b\n> ```\n")
		let box = written.callout("note")
		try #require(box.count == 4)
		#expect(box[1].contains("<w:b/>"))
		#expect(box[2].contains("<w:i/>"))
		#expect(box[3].contains("Courier New"))
		#expect(box[3].contains("<w:t xml:space=\"preserve\">a</w:t><w:br/><w:t xml:space=\"preserve\">  b</w:t>"))
		#expect(!written.document.contains("<w:tbl>"))                  // no code table splitting the box
	}

	@Test("A thematic break is a rule paragraph with the CSS hr margins, and reads back as `---`")
	func ruleRoundTrips() throws {
		let markdown = "Above.\n\n---\n\nBelow."
		#expect(try roundTrip(markdown) == markdown)
		let written = try write(markdown)
		let rule = try #require(written.paragraphs.first { $0.contains("\"SwiftTextRule\"") })
		let ruleMargin = twips(MarkdownAlertLayout.ruleMarginEm)
		#expect(value("w:before", of: "w:spacing", in: rule) == ruleMargin - DocxWriter.paragraphSpaceAfter - DocxBoxLayout.hairlineTwips)
		#expect(value("w:after", of: "w:spacing", in: rule) == ruleMargin + twips(MarkdownAlertLayout.halfLeadingEm))
		#expect(written.styles.contains("<w:name w:val=\"Horizontal Rule\"/>"))
	}

	@Test("Hard line breaks become w:br, not a newline Word shows as a space")
	func hardLineBreaks() throws {
		let document = try write("First line\\\nsecond line\n").document
		#expect(document.contains("<w:r><w:br/></w:r>"))
		#expect(!document.contains("\n</w:t>"))
	}

	@Test("Callout styles are recognised by name when another app rewrote their ids")
	func styleRecognitionByName() {
		#expect(DocxStyleID.callout(styleId: "SwiftTextCalloutTitle-note", name: nil)?.kind == "note")
		#expect(DocxStyleID.callout(styleId: "SwiftTextCalloutTitle-note", name: nil)?.isTitle == true)
		#expect(DocxStyleID.callout(styleId: "CalloutWatch-out", name: "Callout Watch-out")?.kind == "watch-out")
		#expect(DocxStyleID.callout(styleId: "CalloutNoteTitle", name: "Callout Note Title")?.isTitle == true)
		#expect(DocxStyleID.callout(styleId: "Heading1", name: "heading 1") == nil)
		#expect(DocxStyleID.callout(styleId: "Callout", name: "Callout two words") == nil)
	}
}
