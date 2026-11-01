import Foundation
import Testing

@testable import SwiftTextPages
import SwiftTextIWA
import SwiftTextMarkdown

/// `text-align` on `p` and `li` (``MarkdownTextAlignment``): set on the Body style, so body
/// paragraphs and list items are aligned while headings, quotes, code, alert boxes, rules
/// and table cells keep their own alignment.
@Suite("Pages paragraph alignment")
struct PagesAlignmentTests {
	private static let markdown = """
	# Heading

	Intro paragraph.

	- First item
	- Second item

	> A quote.

	Before the note.

	> [!NOTE]
	> A note.

	After the note.

	```
	code
	```

	---

	| Left | Right |
	|:-----|------:|
	| a    | b     |

	#### Small heading
	"""

	/// The paragraph styles of a written document: the stylesheet's by object id, the
	/// synthesized ones (in `Document.iwa`) by object id, and each body paragraph's style id
	/// by its text.
	private struct Written {
		var stylesheet: [UInt64: TSWP_ParagraphStyleArchive] = [:]
		var stylesheetBytes: [UInt8] = []
		var synthesized: [UInt64: TSWP_ParagraphStyleArchive] = [:]
		var paragraphStyles: [String: UInt64] = [:]
		var markdown = ""

		func style(_ id: UInt64) -> TSWP_ParagraphStyleArchive? { stylesheet[id] ?? synthesized[id] }
	}

	private func write(_ markdown: String = Self.markdown, alignment: MarkdownTextAlignment) throws -> Written {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("swifttext-align-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToPages.convert(markdown, to: url, textAlignment: alignment)
		var written = Written()
		let entries = try IWAContainer.entries(at: url, prefix: "Index/")
		let stylesheet = try #require(entries.first { $0.path.hasSuffix("DocumentStylesheet.iwa") })
		written.stylesheetBytes = [UInt8](stylesheet.data)
		for object in try IWAArchive.objects(from: stylesheet.data) where object.type == 2022 {
			written.stylesheet[object.identifier] = TSWP_ParagraphStyleArchive(ProtobufMessage(object.payload))
		}
		let document = try #require(entries.first { $0.path.hasSuffix("/Document.iwa") })
		for object in try IWAArchive.objects(from: document.data) {
			if object.type == 2022 {
				written.synthesized[object.identifier] = TSWP_ParagraphStyleArchive(ProtobufMessage(object.payload))
			}
			let storage = ProtobufMessage(object.payload)
			guard object.type == 2001, let text = storage.bytes(3).map({ String(decoding: $0, as: UTF8.self) }),
				  text.contains("Intro paragraph."), let table = storage.message(5) else { continue }
			let texts = text.components(separatedBy: "\u{2029}")
			for (text, entry) in zip(texts, table.messages(1)) {
				if let id = entry.message(2)?.varint(1) { written.paragraphStyles[text] = id }
			}
		}
		written.markdown = try PagesFile(url: url).markdown()
		return written
	}

	private func alignment(of style: TSWP_ParagraphStyleArchive?) -> Int32? { style?.paraProperties?.alignment }

	private func parent(of style: TSWP_ParagraphStyleArchive?) -> UInt64? { style?.super?.parent?.identifier }

	/// The styles that must keep the template's alignment.
	private static let ownStyles: [UInt64] = [
		PagesStyleID.title, PagesStyleID.heading1, PagesStyleID.heading2, PagesStyleID.heading3, PagesStyleID.heading4,
		PagesStyleID.blockQuote, PagesStyleID.codeBlock, PagesStyleID.calloutBody, PagesStyleID.calloutTitle, PagesStyleID.rule
	]

	@Test("`justify` sets alignment 3 on the Body style, and on nothing else")
	func justifyBody() throws {
		let plain = try write(alignment: .unspecified)
		let justified = try write(alignment: MarkdownTextAlignment(css: "p, li { text-align: justify }"))
		#expect(alignment(of: plain.stylesheet[PagesStyleID.body]) == 4)            // the template's "natural"
		#expect(alignment(of: justified.stylesheet[PagesStyleID.body]) == 3)
		for id in Self.ownStyles {
			#expect(alignment(of: justified.stylesheet[id]) == alignment(of: plain.stylesheet[id]), "style \(id)")
		}
		// Paragraphs and list items use Body itself: no variation is needed.
		#expect(justified.paragraphStyles["Intro paragraph."] == PagesStyleID.body)
		#expect(justified.paragraphStyles["First item"] == PagesStyleID.body)
		#expect(justified.synthesized.values.allSatisfy { alignment(of: $0) == nil })
	}

	@Test("A spacing variation of Body inherits its alignment")
	func spacingVariationInherits() throws {
		let justified = try write(alignment: MarkdownTextAlignment(paragraph: .justify, listItem: .justify))
		// The paragraph before the note gets the box's margin as its space after: a variation of Body.
		let after = try #require(justified.paragraphStyles["Before the note."])
		#expect(after != PagesStyleID.body)
		#expect(parent(of: justified.style(after)) == PagesStyleID.body)
		#expect(alignment(of: justified.style(after)) == nil)
		// The note keeps the Callout alignment.
		let note = try #require(justified.paragraphStyles["A note."])
		#expect(parent(of: justified.style(note)) == PagesStyleID.calloutBody)
		#expect(alignment(of: justified.style(note)) == nil)
	}

	@Test("List items with their own `li` alignment use a variation of Body")
	func listItemVariation() throws {
		let written = try write(alignment: MarkdownTextAlignment(css: "p { text-align: left } li { text-align: justify }"))
		#expect(alignment(of: written.stylesheet[PagesStyleID.body]) == 0)
		let item = try #require(written.paragraphStyles["First item"])
		#expect(written.paragraphStyles["Second item"] == item)
		#expect(parent(of: written.style(item)) == PagesStyleID.body)
		#expect(written.style(item)?.super?.isVariation == true)
		#expect(alignment(of: written.style(item)) == 3)
		#expect(written.paragraphStyles["Intro paragraph."] == PagesStyleID.body)
	}

	@Test("With `li` only, Body keeps the template's alignment and list items get theirs")
	func listItemOnly() throws {
		let written = try write(alignment: MarkdownTextAlignment(css: "li { text-align: justify }"))
		#expect(alignment(of: written.stylesheet[PagesStyleID.body]) == 4)
		let item = try #require(written.paragraphStyles["First item"])
		#expect(alignment(of: written.style(item)) == 3)
	}

	@Test("Under a centred Body, a table's anchor paragraph is pinned left; under justify it isn't")
	func tableAnchor() throws {
		let centred = try write(alignment: MarkdownTextAlignment(paragraph: .center))
		let anchor = try #require(centred.paragraphStyles["\u{FFFC}"])
		#expect(parent(of: centred.style(anchor)) == PagesStyleID.body)
		#expect(alignment(of: centred.style(anchor)) == 0)
		#expect(centred.paragraphStyles["Intro paragraph."] == PagesStyleID.body)

		let justified = try write(alignment: MarkdownTextAlignment(paragraph: .justify))
		#expect(justified.paragraphStyles["\u{FFFC}"] == PagesStyleID.body)
	}

	@Test("Table cells keep their column alignment")
	func tableCells() throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("swifttext-align-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToPages.convert(Self.markdown, to: url, textAlignment: MarkdownTextAlignment(paragraph: .justify))
		let markdown = try PagesFile(url: url).markdown()
		#expect(markdown.contains("| Left | Right |\n| --- | --: |"))
	}

	@Test("Without alignment the stylesheet is unchanged, and alignment doesn't change the Markdown read back")
	func unchangedWithoutAlignment() throws {
		let first = try write(alignment: .unspecified)
		let second = try write(alignment: MarkdownTextAlignment(css: "h1 { text-align: center }"))
		#expect(first.stylesheetBytes == second.stylesheetBytes)
		let justified = try write(alignment: MarkdownTextAlignment(css: "p { text-align: center } li { text-align: justify }"))
		#expect(justified.markdown == first.markdown)
	}

	@Test("The alignment setter replaces an existing value rather than adding a second")
	func setterReplaces() {
		var properties = ProtobufWriter()
		properties.varintField(1, 4)
		properties.fixed32Field(20, Float(8).bitPattern)
		var style = ProtobufWriter()
		style.bytesField(12, properties.bytes)
		let payload = PagesBodySerializer.settingAlignment(in: style.bytes, value: 3)
		let paraProperties = ProtobufMessage(payload).message(12)
		#expect(paraProperties?.allVarints(1) == [3])
		#expect(paraProperties?.float(20) == 8)
	}
}
