import Foundation
import Testing

@testable import SwiftTextPages
import SwiftTextIWA

/// Exercises the reverse-engineered run tables end-to-end (parser → Markdown):
/// the character-style table (bold/italic) and the list tables (level +
/// bullet/number marker, including style inheritance). Guards the IWA field
/// numbers against regressions.
@Suite("Formatting & lists from IWA run tables")
struct PagesFormattingTests {
	private func bundle(documentObjects: [IWAWriter.Object]) throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("fmt-\(UUID().uuidString).pages", isDirectory: true)
		let indexDir = url.appendingPathComponent("Index", isDirectory: true)
		try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
		try IWAWriter.iwaFile(documentObjects).write(to: indexDir.appendingPathComponent("Document.iwa"))
		return url
	}

	/// Wrapper field holding repeated `{1: index, 2: {1: ref}}` run entries.
	private func runTable(_ field: Int, _ entries: [(index: Int, ref: Int)]) -> [UInt8] {
		var inner = [UInt8]()
		for entry in entries {
			let body = IWAWriter.varintField(1, entry.index) + IWAWriter.bytesField(2, IWAWriter.varintField(1, entry.ref))
			inner += IWAWriter.bytesField(1, body)
		}
		return IWAWriter.bytesField(field, inner)
	}

	@Test("Bold/italic from the character-style table and a bullet from the list tables")
	func emphasisAndBulletList() throws {
		let text = "Hello world\nItem"  // "world" at offset 6; "Item" at offset 12

		// Char-style runs (field 8): plain, then bold at "world", plain again at "Item".
		let charTable = runTable(8, [(0, 60), (6, 61), (12, 60)])
		// Para-data (field 6): list level per paragraph (both level 0).
		let paraData = IWAWriter.bytesField(6,
			IWAWriter.bytesField(1, IWAWriter.varintField(1, 0) + IWAWriter.varintField(3, 0))
				+ IWAWriter.bytesField(1, IWAWriter.varintField(1, 12) + IWAWriter.varintField(3, 0)))
		// List-style runs (field 7): None for the first paragraph, a bullet for "Item".
		let listTable = runTable(7, [(0, 70), (12, 71)])

		let body = IWAWriter.varintField(1, 0)
			+ IWAWriter.stringField(3, text)
			+ paraData + listTable + charTable

		let objects: [IWAWriter.Object] = [
			.init(identifier: 10, type: 2001, payload: body),
			// Character styles: char_properties (field 11) with bold (1) / italic (2).
			.init(identifier: 60, type: 2021, payload: IWAWriter.bytesField(11, IWAWriter.varintField(1, 0))),
			.init(identifier: 61, type: 2021, payload: IWAWriter.bytesField(11, IWAWriter.varintField(1, 1))),
			// List styles: per-level marker type (field 11): 0 = none, 2 = bullet.
			.init(identifier: 70, type: 2023, payload: IWAWriter.varintField(11, 0)),
			.init(identifier: 71, type: 2023, payload: IWAWriter.varintField(11, 2))
		]

		let url = try bundle(documentObjects: objects)
		defer { try? FileManager.default.removeItem(at: url) }
		let pages = try PagesFile(url: url)
		#expect(pages.markdown() == "Hello **world**\n\n- Item")
		// Plain text keeps the visible list marker (the bullet Pages draws).
		#expect(pages.plainText() == "Hello world\n\n• Item")
	}

	@Test("Strikethrough from the character-style table")
	func strikethroughFromCharStyle() throws {
		let text = "hi struck"  // "struck" at offset 3
		let charTable = runTable(8, [(0, 60), (3, 62)])
		let body = IWAWriter.varintField(1, 0) + IWAWriter.stringField(3, text) + charTable
		let objects: [IWAWriter.Object] = [
			.init(identifier: 10, type: 2001, payload: body),
			.init(identifier: 60, type: 2021, payload: IWAWriter.bytesField(11, IWAWriter.varintField(1, 0))),
			// char_properties strikethrough flag is field 12.
			.init(identifier: 62, type: 2021, payload: IWAWriter.bytesField(11, IWAWriter.varintField(12, 1)))
		]
		let url = try bundle(documentObjects: objects)
		defer { try? FileManager.default.removeItem(at: url) }
		#expect(try PagesFile(url: url).markdown() == "hi ~~struck~~")
	}

	@Test("Underline from the character-style table")
	func underlineFromCharStyle() throws {
		let text = "plain under plain"
		let charTable = runTable(8, [(0, 60), (6, 62), (11, 60)])
		let body = IWAWriter.varintField(1, 0) + IWAWriter.stringField(3, text) + charTable
		let objects: [IWAWriter.Object] = [
			.init(identifier: 10, type: 2001, payload: body),
			.init(identifier: 60, type: 2021, payload: IWAWriter.bytesField(11, IWAWriter.varintField(11, 0))),
			.init(identifier: 62, type: 2021, payload: IWAWriter.bytesField(11, IWAWriter.varintField(11, 1)))
		]
		let url = try bundle(documentObjects: objects)
		defer { try? FileManager.default.removeItem(at: url) }
		#expect(try PagesFile(url: url).markdown() == "plain <u>under</u> plain")
	}

	@Test("Footnote references become [^N] with definitions appended")
	func footnotes() throws {
		// Body "Claim" with a footnote mark at offset 5 (end), referencing a
		// footnote-mark object that points to a kind-2 content storage.
		let body = IWAWriter.varintField(1, 0) + IWAWriter.stringField(3, "Claim") + runTable(16, [(index: 5, ref: 20)])
		let mark = IWAWriter.bytesField(1, IWAWriter.varintField(1, 30))           // mark -> storage 30
		let footStorage = IWAWriter.varintField(1, 2) + IWAWriter.stringField(3, "\u{FFFC} the note")  // kind 2

		let objects: [IWAWriter.Object] = [
			.init(identifier: 10, type: 2001, payload: body),
			.init(identifier: 20, type: 2008, payload: mark),
			.init(identifier: 30, type: 2001, payload: footStorage)
		]
		let url = try bundle(documentObjects: objects)
		defer { try? FileManager.default.removeItem(at: url) }
		#expect(try PagesFile(url: url).markdown() == "Claim[^1]\n\n[^1]: the note")
	}

	@Test("A bold paragraph style renders the whole paragraph bold")
	func paragraphStyleBold() throws {
		let text = "Headline\nBody text here."  // second paragraph at offset 9

		let paraTable = runTable(5, [(0, 90), (9, 91)])
		let body = IWAWriter.varintField(1, 0) + IWAWriter.stringField(3, text) + paraTable

		let objects: [IWAWriter.Object] = [
			.init(identifier: 10, type: 2001, payload: body),
			// Paragraph styles: char_properties (field 11) carrying the bold flag —
			// no character-style runs at all, like a document styled per paragraph.
			.init(identifier: 90, type: 2022, payload: IWAWriter.bytesField(11, IWAWriter.varintField(1, 1))),
			.init(identifier: 91, type: 2022, payload: IWAWriter.bytesField(11, IWAWriter.varintField(1, 0)))
		]

		let url = try bundle(documentObjects: objects)
		defer { try? FileManager.default.removeItem(at: url) }
		let pages = try PagesFile(url: url)
		#expect(pages.markdown() == "**Headline**\n\nBody text here.")
		#expect(pages.plainText() == "Headline\n\nBody text here.")
	}

	@Test("An anonymous paragraph style inherits bold and font size from its parent")
	func paragraphStyleInheritance() throws {
		let text = "Warning\nBody text long enough to dominate.\nMore body text at the same size."

		let paraTable = runTable(5, [(0, 92), (8, 91)])
		let body = IWAWriter.varintField(1, 0) + IWAWriter.stringField(3, text) + paraTable

		// 92 sets nothing itself; its super (field 1) points via parent (field 3)
		// at 93, which is bold and 28pt — the pattern Pages writes when a user
		// restyles a paragraph ("Body + tweaks" anonymous styles).
		let anonymous = IWAWriter.bytesField(1, IWAWriter.bytesField(3, IWAWriter.varintField(1, 93)))
		let parent = IWAWriter.bytesField(11, IWAWriter.varintField(1, 1) + IWAWriter.floatField(3, 28))
		let bodyStyle = IWAWriter.bytesField(11, IWAWriter.varintField(1, 0) + IWAWriter.floatField(3, 12))

		let objects: [IWAWriter.Object] = [
			.init(identifier: 10, type: 2001, payload: body),
			.init(identifier: 92, type: 2022, payload: anonymous),
			.init(identifier: 93, type: 2022, payload: parent),
			.init(identifier: 91, type: 2022, payload: bodyStyle)
		]

		let url = try bundle(documentObjects: objects)
		defer { try? FileManager.default.removeItem(at: url) }
		let markdown = try PagesFile(url: url).markdown()
		// The inherited 28pt (vs. 12pt body) promotes the paragraph to a heading,
		// and the inherited bold is suppressed there — not `# **Warning**`.
		#expect(markdown.hasPrefix("# Warning"))
		#expect(!markdown.contains("**"))
	}

	@Test("Character runs override only the fields they set on a bold paragraph")
	func characterOverridesOnBoldParagraph() throws {
		let text = "AAAA BBBB CCCC"

		let paraTable = runTable(5, [(0, 90)])
		// Char runs: inherit, explicitly not-bold at "BBBB", inherit again — the
		// unreferenced entries fall through to the paragraph's bold.
		var charTable = [UInt8]()
		charTable += IWAWriter.bytesField(1, IWAWriter.varintField(1, 0))
		charTable += IWAWriter.bytesField(1, IWAWriter.varintField(1, 5) + IWAWriter.bytesField(2, IWAWriter.varintField(1, 94)))
		charTable += IWAWriter.bytesField(1, IWAWriter.varintField(1, 10))
		let body = IWAWriter.varintField(1, 0) + IWAWriter.stringField(3, text)
			+ paraTable + IWAWriter.bytesField(8, charTable)

		let objects: [IWAWriter.Object] = [
			.init(identifier: 10, type: 2001, payload: body),
			.init(identifier: 90, type: 2022, payload: IWAWriter.bytesField(11, IWAWriter.varintField(1, 1))),
			// An explicit bold = 0 override (present field wins over the paragraph).
			.init(identifier: 94, type: 2021, payload: IWAWriter.bytesField(11, IWAWriter.varintField(1, 0)))
		]

		let url = try bundle(documentObjects: objects)
		defer { try? FileManager.default.removeItem(at: url) }
		#expect(try PagesFile(url: url).markdown() == "**AAAA** BBBB **CCCC**")
	}

	@Test("An italic character run on a bold paragraph combines to bold italic")
	func italicRunOnBoldParagraph() throws {
		let text = "AAAA BBBB CCCC"

		let paraTable = runTable(5, [(0, 90)])
		var charTable = [UInt8]()
		charTable += IWAWriter.bytesField(1, IWAWriter.varintField(1, 0))
		charTable += IWAWriter.bytesField(1, IWAWriter.varintField(1, 5) + IWAWriter.bytesField(2, IWAWriter.varintField(1, 95)))
		charTable += IWAWriter.bytesField(1, IWAWriter.varintField(1, 10))
		let body = IWAWriter.varintField(1, 0) + IWAWriter.stringField(3, text)
			+ paraTable + IWAWriter.bytesField(8, charTable)

		let objects: [IWAWriter.Object] = [
			.init(identifier: 10, type: 2001, payload: body),
			.init(identifier: 90, type: 2022, payload: IWAWriter.bytesField(11, IWAWriter.varintField(1, 1))),
			// Sets only italic — bold is absent, so the paragraph's bold shows through.
			.init(identifier: 95, type: 2021, payload: IWAWriter.bytesField(11, IWAWriter.varintField(2, 1)))
		]

		let url = try bundle(documentObjects: objects)
		defer { try? FileManager.default.removeItem(at: url) }
		#expect(try PagesFile(url: url).markdown() == "**AAAA** ***BBBB*** **CCCC**")
	}

	@Test("A tweaked (anonymous) heading style still maps to a heading via its parent")
	func headingIdentifierThroughParent() throws {
		let text = "Section\nBody."

		let paraTable = runTable(5, [(0, 96), (8, 91)])
		let body = IWAWriter.varintField(1, 0) + IWAWriter.stringField(3, text) + paraTable

		// 96: anonymous, bold tweak, parent 97. 97 carries the stable heading identifier.
		let anonymous = IWAWriter.bytesField(1, IWAWriter.bytesField(3, IWAWriter.varintField(1, 97)))
			+ IWAWriter.bytesField(11, IWAWriter.varintField(1, 1))
		let heading = IWAWriter.bytesField(1, IWAWriter.stringField(2, "text-1-paragraphstyle-Heading 2"))
			+ IWAWriter.bytesField(11, IWAWriter.varintField(1, 1))

		let objects: [IWAWriter.Object] = [
			.init(identifier: 10, type: 2001, payload: body),
			.init(identifier: 96, type: 2022, payload: anonymous),
			.init(identifier: 97, type: 2022, payload: heading),
			.init(identifier: 91, type: 2022, payload: [])
		]

		let url = try bundle(documentObjects: objects)
		defer { try? FileManager.default.removeItem(at: url) }
		let markdown = try PagesFile(url: url).markdown()
		#expect(markdown.hasPrefix("## Section"))
		#expect(!markdown.contains("**"))
	}

	@Test("A rich cell keeps distinct paragraph styles across its paragraphs")
	func cellWithMixedParagraphStyles() throws {
		// "Plain" in a regular paragraph style, "Bold" in a bold one at offset 6,
		// with an italic-only character run over it — the paragraph baseline and
		// the character override must combine per offset, not from one shared base.
		let text = "Plain\nBold"
		let paraTable = runTable(5, [(0, 200), (6, 201)])
		var charTable = [UInt8]()
		charTable += IWAWriter.bytesField(1, IWAWriter.varintField(1, 0))
		charTable += IWAWriter.bytesField(1, IWAWriter.varintField(1, 6) + IWAWriter.bytesField(2, IWAWriter.varintField(1, 202)))
		let payload = IWAWriter.varintField(1, 0) + IWAWriter.stringField(3, text)
			+ paraTable + IWAWriter.bytesField(8, charTable)

		var store = IWAObjectStore()
		store.add(IWAObject(identifier: 200, type: 2022, payload: IWAWriter.bytesField(11, IWAWriter.varintField(1, 0))))
		store.add(IWAObject(identifier: 201, type: 2022, payload: IWAWriter.bytesField(11, IWAWriter.varintField(1, 1))))
		store.add(IWAObject(identifier: 202, type: 2021, payload: IWAWriter.bytesField(11, IWAWriter.varintField(2, 1))))
		let cell = IWAObject(identifier: 10, type: 2001, payload: payload)

		#expect(PagesParser().cellMarkdown(cell, store: store) == "Plain\n***Bold***")
	}

	@Test("Numbered list with an anonymous style inheriting its marker from a parent")
	func numberedListWithInheritance() throws {
		let text = "One\nTwo"  // "Two" at offset 4

		let paraData = IWAWriter.bytesField(6,
			IWAWriter.bytesField(1, IWAWriter.varintField(1, 0) + IWAWriter.varintField(3, 0))
				+ IWAWriter.bytesField(1, IWAWriter.varintField(1, 4) + IWAWriter.varintField(3, 0)))
		let listTable = runTable(7, [(0, 81), (4, 81)])  // both paragraphs share the anonymous style

		let body = IWAWriter.varintField(1, 0) + IWAWriter.stringField(3, text) + paraData + listTable

		// Anonymous list style 81 has no field 11; its base (field 1) points via
		// field 3 at parent 80, which defines the numbered marker (3).
		let anonymousBase = IWAWriter.bytesField(3, IWAWriter.varintField(1, 80))
		let objects: [IWAWriter.Object] = [
			.init(identifier: 10, type: 2001, payload: body),
			.init(identifier: 80, type: 2023, payload: IWAWriter.varintField(11, 3)),
			.init(identifier: 81, type: 2023, payload: IWAWriter.bytesField(1, anonymousBase))
		]

		let url = try bundle(documentObjects: objects)
		defer { try? FileManager.default.removeItem(at: url) }
		let pages = try PagesFile(url: url)
		#expect(pages.markdown() == "1. One\n2. Two")
		// Plain text keeps the visible numbering too.
		#expect(pages.plainText() == "1. One\n\n2. Two")
	}
}
