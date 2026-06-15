import Foundation
import Testing

@testable import SwiftTextPages

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
			.init(identifier: 71, type: 2023, payload: IWAWriter.varintField(11, 2)),
		]

		let url = try bundle(documentObjects: objects)
		defer { try? FileManager.default.removeItem(at: url) }
		let pages = try PagesFile(url: url)
		#expect(pages.markdown() == "Hello **world**\n\n- Item")
		#expect(pages.plainText() == "Hello world\n\nItem")
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
			.init(identifier: 62, type: 2021, payload: IWAWriter.bytesField(11, IWAWriter.varintField(12, 1))),
		]
		let url = try bundle(documentObjects: objects)
		defer { try? FileManager.default.removeItem(at: url) }
		#expect(try PagesFile(url: url).markdown() == "hi ~~struck~~")
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
			.init(identifier: 30, type: 2001, payload: footStorage),
		]
		let url = try bundle(documentObjects: objects)
		defer { try? FileManager.default.removeItem(at: url) }
		#expect(try PagesFile(url: url).markdown() == "Claim[^1]\n\n[^1]: the note")
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
			.init(identifier: 81, type: 2023, payload: IWAWriter.bytesField(1, anonymousBase)),
		]

		let url = try bundle(documentObjects: objects)
		defer { try? FileManager.default.removeItem(at: url) }
		#expect(try PagesFile(url: url).markdown() == "1. One\n2. Two")
	}
}
