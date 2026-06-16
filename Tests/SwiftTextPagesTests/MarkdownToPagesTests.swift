import Foundation
import Testing

@testable import SwiftTextPages

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

	/// Loads every `Index/*.iwa` object from a written `.pages` into one store.
	private func objectStore(at url: URL) throws -> IWAObjectStore {
		var store = IWAObjectStore()
		for entry in try PagesContainer.entries(at: url, prefix: "Index/", suffix: ".iwa") {
			guard let objects = try? IWAArchive.objects(from: entry.data) else { continue }
			for object in objects { store.add(object) }
		}
		return store
	}

	@Test("A link becomes a clickable hyperlink object (type 2032) referenced from the body")
	func linkProducesHyperlinkObject() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-link-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToPages.convert("See [Cocoanetics](https://www.cocoanetics.com).", to: url)

		// The Document component must carry a TSWP hyperlink object (type 2032)
		// whose field 2 is the destination URL.
		let entries = try PagesContainer.entries(at: url, prefix: "Index/", suffix: ".iwa")
		let documentData = try #require(entries.first { $0.path.hasSuffix("Document.iwa") }?.data)
		let hyperlinks = try IWAArchive.objects(from: documentData).filter { $0.type == 2032 }
		#expect(hyperlinks.count == 1)
		let urlField = hyperlinks.first.flatMap { ProtobufMessage($0.payload).bytes(2) }
		#expect(urlField.map { String(decoding: $0, as: UTF8.self) } == "https://www.cocoanetics.com")
	}
}
