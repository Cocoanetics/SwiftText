import Foundation
import Testing
import Markdown

@testable import SwiftTextPages
import SwiftTextIWA

@Suite("Markdown → Pages")
struct MarkdownToPagesTests {
	static let sample = """
	# Document Title

	A paragraph with **bold**, *italic*, ***both***, ~~strike~~, and `inline code`.

	## Section Two

	Some intro text.

	- First bullet
	- Second bullet
	  - Nested bullet

	1. First numbered
	2. Second numbered

	```
	let x = 42
	print(x)
	```

	> A block quote.

	| Name | Count |
	|------|-------|
	| Apples | 3 |
	| Pears | 5 |

	---

	An image ![a diagram](diagram.png) and a [link](https://example.com).
	"""

	@Test("A rich Markdown document writes and reads back through PagesFile")
	func richDocumentRoundTrips() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-md-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }

		try MarkdownToPages.convert(Self.sample, to: url)

		let markdown = try PagesFile(url: url).markdown()
		// Headings, inline styling, lists, code, and the image placeholder survive.
		#expect(markdown.contains("Document Title"))
		#expect(markdown.contains("**bold**"))
		#expect(markdown.contains("*italic*"))
		#expect(markdown.contains("~~strike~~"))
		#expect(markdown.contains("First bullet"))
		#expect(markdown.contains("Nested bullet"))
		#expect(markdown.contains("First numbered"))
		#expect(markdown.contains("let x = 42"))
		#expect(markdown.contains("block quote"))
		#expect(markdown.contains("a diagram"))   // image placeholder text
		#expect(markdown.contains("link"))
		#expect(markdown.contains("Name"))        // table header cell
		#expect(markdown.contains("Apples"))      // table body cell
		#expect(markdown.contains("Pears"))
	}

	@Test("Extracted underline Markdown re-imports as Pages formatting")
	func underlineReimports() throws {
		let source = PagesDocument(paragraphs: [
			.init(text: "plain under bold", emphasis: [
				.init(start: 0, bold: false, italic: false),
				.init(start: 6, bold: false, italic: false, underline: true),
				.init(start: 12, bold: true, italic: false, underline: true)
			])
		])
		let markdown = source.markdown()
		#expect(markdown == "plain <u>under</u> <u>**bold**</u>")

		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-underline-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToPages.convert(markdown, to: url)

		#expect(try PagesFile(url: url).markdown() == markdown)
	}

	@Test("A Markdown table becomes a native iWork table grid that round-trips")
	func tableProducesNativeGrid() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-table-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		let markdown = """
		| Product | Region | Units |
		|---------|--------|-------|
		| Widget | North | 120 |
		| Gadget | South | 85 |
		"""
		try MarkdownToPages.convert(markdown, to: url)

		// The native table object graph is present: a drawable attachment (2003)
		// anchors the body, the model (6001) carries the 3×3 dimensions, and the cell
		// strings live in a TableDataList (6005).
		let store = try objectStore(at: url)
		#expect(store.objects(ofType: 2003).count == 1)
		let model = try #require(store.objects(ofType: 6001).first)
		let modelMessage = ProtobufMessage(model.payload)
		#expect(modelMessage.varint(6) == 3)   // rows (1 header + 2 body)
		#expect(modelMessage.varint(7) == 3)   // columns
		let cellStrings = store.objects(ofType: 6005)
			.flatMap { ProtobufMessage($0.payload).messages(3) }
			.compactMap { $0.bytes(3).map { String(decoding: $0, as: UTF8.self) } }
		#expect(Set(cellStrings).isSuperset(of: ["Product", "Region", "Units", "Widget", "North", "120", "Gadget", "South", "85"]))

		// And it reads back as a Markdown table (full round-trip through the reader).
		let readBack = try PagesFile(url: url).markdown()
		#expect(readBack.contains("| Product | Region | Units |"))
		#expect(readBack.contains("| --- | --- | --- |"))
		#expect(readBack.contains("| Widget | North | 120 |"))
	}

	@Test("Multiple tables each become a distinct native grid and round-trip")
	func multipleTablesAreNative() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-tables-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		let markdown = """
		| Product | Units |
		|---------|-------|
		| Widget | 120 |

		Between the tables.

		| Name | Role |
		|------|------|
		| Alice | Lead |
		| Bob | Dev |
		"""
		try MarkdownToPages.convert(markdown, to: url)

		// Two independent native tables: two drawable attachments (2003) and two
		// models (6001), each with its own dimensions and id range (no collision).
		let store = try objectStore(at: url)
		#expect(store.objects(ofType: 2003).count == 2)
		let models = store.objects(ofType: 6001)
		#expect(models.count == 2)
		let dimensions = Set(models.map { model -> String in
			let m = ProtobufMessage(model.payload)
			return "\(m.varint(6) ?? 0)x\(m.varint(7) ?? 0)"
		})
		#expect(dimensions == ["2x2", "3x2"])   // 1 header + 1 body × 2 cols; 1 header + 2 body × 2 cols

		// Both tables read back as Markdown tables.
		let readBack = try PagesFile(url: url).markdown()
		#expect(readBack.contains("| Product | Units |"))
		#expect(readBack.contains("| Widget | 120 |"))
		#expect(readBack.contains("| Name | Role |"))
		#expect(readBack.contains("| Alice | Lead |"))
		#expect(readBack.contains("| Bob | Dev |"))
	}

	@Test("Markdown column alignment round-trips through native table cells")
	func tableColumnAlignmentRoundTrips() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-align-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		let markdown = """
		| Left | Center | Right |
		|:-----|:------:|------:|
		| a | b | c |
		| dd | ee | ff |
		"""
		try MarkdownToPages.convert(markdown, to: url)

		// Alignment styles are synthesized (a right `#12 = 1` and a center `#12 = 2`
		// paragraph style) and reachable; the delimiter row round-trips the markers.
		let store = try objectStore(at: url)
		let alignmentValues = store.objects(ofType: 2022)
			.compactMap { ProtobufMessage($0.payload).message(12)?.varint(1) }
		#expect(alignmentValues.contains(1))
		#expect(alignmentValues.contains(2))

		let readBack = try PagesFile(url: url).markdown()
		#expect(readBack.contains("| --- | :-: | --: |"))
	}

	@Test("In-cell bold/italic round-trips through native table rich-text cells")
	func tableInCellFormattingRoundTrips() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-cellfmt-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		let markdown = """
		| Fruit | Note |
		|-------|------|
		| Apple | **fresh** fruit |
		| Pear | a *ripe* one |
		"""
		try MarkdownToPages.convert(markdown, to: url)

		let store = try objectStore(at: url)
		// A rich cell becomes a cell-text StorageArchive (2001) wrapped by a type-6218
		// object that the rich_text_table points at. The storage holds the *unmarked*
		// text; the bold/italic live in 2021 character-style runs (#8).
		#expect(store.objects(ofType: 6218).count == 2)
		let cellStorageTexts = store.objects(ofType: 2001).compactMap {
			ProtobufMessage($0.payload).bytes(3).map { String(decoding: $0, as: UTF8.self) }
		}
		#expect(cellStorageTexts.contains("fresh fruit"))   // no `**` in the stored text
		#expect(cellStorageTexts.contains("a ripe one"))    // no `*` in the stored text

		// The reader reconstructs the inline markers from those runs.
		let readBack = try PagesFile(url: url).markdown()
		#expect(readBack.contains("| Apple | **fresh** fruit |"))
		#expect(readBack.contains("| Pear | a *ripe* one |"))
	}

	@Test("A cell that is both aligned and formatted keeps both (alignment + inline)")
	func tableAlignedAndFormattedCellRoundTrips() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-alignfmt-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		// Center and Right columns have a rich cell in every body row, so the column
		// alignment can only be recovered through the rich (storage paragraph style)
		// path — proving inline formatting and alignment compose in one cell.
		let markdown = """
		| Left | Center | Right |
		|:-----|:------:|------:|
		| a | **b** | *c* |
		| dd | **ee** | *ff* |
		"""
		try MarkdownToPages.convert(markdown, to: url)

		let readBack = try PagesFile(url: url).markdown()
		#expect(readBack.contains("| --- | :-: | --: |"))      // alignment survived
		#expect(readBack.contains("| a | **b** | *c* |"))      // formatting survived
		#expect(readBack.contains("| dd | **ee** | *ff* |"))
	}

	@Test("A fully-styled cell emits no out-of-range char run (Pages would drop it)")
	func tableFullCellStyleStaysInRange() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-whole-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		// The styled span is the entire cell, so the run reaches the text end — the case
		// that produced an out-of-range trailing char-run entry.
		try MarkdownToPages.convert("| A | B |\n|---|---|\n| x | **whole** |", to: url)

		let storage = try #require(try objectStore(at: url).objects(ofType: 2001).first {
			ProtobufMessage($0.payload).bytes(3).map { String(decoding: $0, as: UTF8.self) } == "whole"
		})
		let message = ProtobufMessage(storage.payload)
		let length = UInt64(message.bytes(3).map { String(decoding: $0, as: UTF8.self).utf16.count } ?? 0)
		let runIndices = message.message(8)?.messages(1).compactMap { $0.varint(1) } ?? []
		#expect(!runIndices.isEmpty)
		#expect(runIndices.allSatisfy { $0 < length })   // no entry at/after the text end
		#expect(try PagesFile(url: url).markdown().contains("| x | **whole** |"))
	}

	@Test("A document ending in a styled run keeps its char-run table in range")
	func bodyEndingInStyleStaysInRange() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-bodyend-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToPages.convert("A final word in **bold**", to: url)

		let storage = try #require(try objectStore(at: url).objects(ofType: 2001).first {
			(ProtobufMessage($0.payload).bytes(3).map { String(decoding: $0, as: UTF8.self) } ?? "").contains("A final word")
		})
		let message = ProtobufMessage(storage.payload)
		let length = UInt64(message.bytes(3).map { String(decoding: $0, as: UTF8.self).utf16.count } ?? 0)
		let runIndices = message.message(8)?.messages(1).compactMap { $0.varint(1) } ?? []
		#expect(!runIndices.isEmpty)
		#expect(runIndices.allSatisfy { $0 < length })   // a trailing styled run extends to the end
		#expect(try PagesFile(url: url).markdown().contains("**bold**"))
	}

	@Test("Separated ordered Markdown lists use separate Pages list instances")
	func separatedOrderedListsUseSeparateNumberingStyles() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-lists-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		let markdown = """
		### Term A

		Definition A

		1. collocation A1
		2. collocation A2
		3. collocation A3

		### Term B

		Definition B

		1. collocation B1
		2. collocation B2
		3. collocation B3
		"""
		try MarkdownToPages.convert(markdown, to: url)

		let store = try objectStore(at: url)
		let body = try #require(store.objects(ofType: 2001).first {
			(ProtobufMessage($0.payload).bytes(3).map { String(decoding: $0, as: UTF8.self) } ?? "")
				.contains("collocation A1")
		})
		let listStyleIDs = ProtobufMessage(body.payload)
			.message(7)?
			.messages(1)
			.compactMap { $0.message(2)?.varint(1) }
			.filter { $0 != PagesStyleID.listNone } ?? []

		#expect(listStyleIDs.count == 6)
		let firstListIDs = Array(listStyleIDs.prefix(3))
		let secondListIDs = Array(listStyleIDs.suffix(3))
		let firstStyle = try #require(firstListIDs.first)
		let secondStyle = try #require(secondListIDs.first)
		#expect(firstStyle != secondStyle)
		#expect(firstListIDs.allSatisfy { $0 == firstStyle })
		#expect(secondListIDs.allSatisfy { $0 == secondStyle })

		for styleID in [firstStyle, secondStyle] {
			let object = try #require(store.object(styleID))
			#expect(object.type == 2023)
			let parent = ProtobufMessage(object.payload).message(1)?.message(3)?.varint(1)
			#expect(parent == PagesStyleID.numberedList)
		}

		let metadata = try #require(store.objects(ofType: 11006).first)
		let highWaterMark = ProtobufMessage(metadata.payload).varint(1) ?? 0
		#expect(highWaterMark >= (listStyleIDs.max() ?? 0))
	}

	@Test("Nested unordered lists do not restart the parent ordered list instance")
	func nestedUnorderedListKeepsParentNumberingStyle() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-mixed-list-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		let markdown = """
		1. One
		   - detail
		2. Two
		"""
		try MarkdownToPages.convert(markdown, to: url)

		let store = try objectStore(at: url)
		let body = try #require(store.objects(ofType: 2001).first {
			(ProtobufMessage($0.payload).bytes(3).map { String(decoding: $0, as: UTF8.self) } ?? "")
				.contains("detail")
		})
		let orderedStyleIDs = ProtobufMessage(body.payload)
			.message(7)?
			.messages(1)
			.compactMap { $0.message(2)?.varint(1) }
			.filter { $0 != PagesStyleID.listNone && $0 != PagesStyleID.bulletList } ?? []

		#expect(orderedStyleIDs.count == 2)
		let firstStyle = try #require(orderedStyleIDs.first)
		#expect(orderedStyleIDs.allSatisfy { $0 == firstStyle })
	}

	/// Loads every `Index/*.iwa` object from a written `.pages` into one store.
	private func objectStore(at url: URL) throws -> IWAObjectStore {
		var store = IWAObjectStore()
		for entry in try IWAContainer.entries(at: url, prefix: "Index/", suffix: ".iwa") {
			guard let objects = try? IWAArchive.objects(from: entry.data) else { continue }
			for object in objects { store.add(object) }
		}
		return store
	}

	@Test("markdownDocument() builds a swift-markdown AST mirroring MarkdownToPages' input")
	func readBackProducesAST() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-ast-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToPages.convert("# Heading\n\nText with a [link](https://x.com) and `code`.\n\n- one\n- two", to: url)

		let ast = try PagesFile(url: url).markdownDocument()
		let blocks = Array(ast.children)
		// First block is a level-1 heading; the inline content includes a Link + InlineCode.
		#expect((blocks.first as? Heading)?.level == 1)
		let inlineKinds = blocks.compactMap { $0 as? Markdown.Paragraph }
			.flatMap { Array($0.children) }
		#expect(inlineKinds.contains { $0 is Link })
		#expect(inlineKinds.contains { $0 is InlineCode })
		// A list block is present.
		#expect(blocks.contains { $0 is UnorderedList })
		// And it serializes to valid Markdown that re-parses to the same shape.
		let formatted = ast.format()
		#expect(formatted.contains("# Heading"))
		#expect(formatted.contains("[link](https://x.com)"))
	}

	@Test("Package form writes a directory bundle (Index.zip + loose files) that re-reads")
	func packageFormRoundTrips() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-pkg-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToPages.convert("# Hi\n\nA **bold** word.", to: url, packaging: .package)

		// It's a directory bundle: nested Index.zip + loose Metadata/ and previews.
		var isDir: ObjCBool = false
		#expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue)
		#expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("Index.zip").path))
		#expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("Metadata").path))

		// And it reads back through the normal reader with the body text intact.
		let text = try PagesFile(url: url).plainText()
		#expect(text.contains("Hi"))
		#expect(text.contains("A bold word."))
	}

	@Test("A link becomes a clickable hyperlink object (type 2032) referenced from the body")
	func linkProducesHyperlinkObject() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-link-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToPages.convert("See [Cocoanetics](https://www.cocoanetics.com).", to: url)

		// The Document component must carry a TSWP hyperlink object (type 2032)
		// whose field 2 is the destination URL.
		let entries = try IWAContainer.entries(at: url, prefix: "Index/", suffix: ".iwa")
		let documentData = try #require(entries.first { $0.path.hasSuffix("Document.iwa") }?.data)
		let hyperlinks = try IWAArchive.objects(from: documentData).filter { $0.type == 2032 }
		#expect(hyperlinks.count == 1)
		let urlField = hyperlinks.first.flatMap { ProtobufMessage($0.payload).bytes(2) }
		#expect(urlField.map { String(decoding: $0, as: UTF8.self) } == "https://www.cocoanetics.com")
	}

	@Test("Literal typographic characters already in the source survive unchanged (issue #38)")
	func literalTypographicCharactersSurvive() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-smartpunct-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToPages.convert("a — b – c… “quoted” ‘single’", to: url)

		let text = try PagesFile(url: url).plainText()
		#expect(text.contains("a — b – c… “quoted” ‘single’"))
	}
}
