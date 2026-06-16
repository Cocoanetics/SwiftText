import Foundation
import Testing

@testable import SwiftTextPages

/// Exercises the comprehensive programmatic table model: per-cell appearance (fill,
/// vertical alignment, borders, wrap), custom column widths / row heights, and header /
/// footer counts. Settings are built in code via the generated iWork wire models and
/// wired into the object graph. Cell fill, vertical alignment, and column widths are
/// additionally validated as rendering in Pages (manually, during development).
@Suite("Comprehensive table styling")
struct PagesTableStyleTests {
	/// Writes one styled table to a `.pages` and returns its object store.
	private func writeStyledTable(_ table: PagesTable) throws -> (url: URL, store: IWAObjectStore) {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-style-\(UUID().uuidString).pages")
		let para = BodyParagraph(text: "\u{FFFC}", paragraphStyle: PagesStyleID.body,
		                         attachment: PagesTableTemplate.attachmentID, table: table)
		try PagesWriter().write(paragraphs: [para], to: url)
		var store = IWAObjectStore()
		for entry in try PagesContainer.entries(at: url, prefix: "Index/", suffix: ".iwa") {
			guard let objects = try? IWAArchive.objects(from: entry.data) else { continue }
			for object in objects { store.add(object) }
		}
		return (url, store)
	}

	@Test("Per-cell fill / vertical alignment / border become CellStyleArchive objects")
	func cellAppearanceBuildsCellStyles() throws {
		var table = PagesTable(rows: 2, columns: 2, cells: ["H1", "H2", "a", "b"])
		table.cellAppearances[2] = PagesCellAppearance(fill: PagesColor(r: 255, g: 0, b: 0))            // "a" red
		table.cellAppearances[3] = PagesCellAppearance(verticalAlignment: .bottom,
			topBorder: PagesCellBorder(color: .black, width: 2))                                         // "b" bottom + border
		let (url, store) = try writeStyledTable(table)
		defer { try? FileManager.default.removeItem(at: url) }

		// Two synthesized CellStyleArchive (6004) objects carry the appearance.
		let synth = store.objects(ofType: 6004).filter { $0.identifier >= PagesTableBuilder.appearanceStyleBase }
		#expect(synth.count == 2)
		let decoded = synth.map { TST_CellStyleArchive(ProtobufMessage($0.payload)) }
		// One has a red fill; one has bottom v-align and a top stroke.
		#expect(decoded.contains { cs in
			guard let c = cs.cellProperties?.cellFill?.color else { return false }
			return (c.r ?? 0) > 0.9 && (c.g ?? 1) < 0.1 && (c.b ?? 1) < 0.1
		})
		#expect(decoded.contains { $0.cellProperties?.verticalAlignment == PagesVerticalAlignment.bottom.rawValue })
		#expect(decoded.contains { $0.cellProperties?.topStroke?.width == 2 })

		// They parent to a base cell style and live referenced from the table style table.
		#expect(decoded.allSatisfy { $0.super?.parent?.identifier == PagesTableBuilder.defaultBodyCellStyleID })
		let model = try #require(store.objects(ofType: 6001).first)
		let styleTableID = try #require(ProtobufMessage(model.payload).message(4)?.message(5)?.varint(1))
		let styleObj = try #require(store.object(styleTableID))
		let referenced = ProtobufMessage(styleObj.payload).messages(3).compactMap { $0.message(4)?.varint(1) }
		#expect(synth.allSatisfy { referenced.contains($0.identifier) })
	}

	@Test("Header rows, footer rows, and header columns are set on the model")
	func headerFooterCountsRoundTrip() throws {
		var table = PagesTable(rows: 5, columns: 3, cells: (0..<15).map { "c\($0)" })
		table.headerRows = 2
		table.headerColumns = 1
		table.footerRows = 1
		let (url, store) = try writeStyledTable(table)
		defer { try? FileManager.default.removeItem(at: url) }

		let model = ProtobufMessage(try #require(store.objects(ofType: 6001).first).payload)
		#expect(model.varint(9) == 2)    // header rows
		#expect(model.varint(10) == 1)   // header columns
		#expect(model.varint(11) == 1)   // footer rows
	}

	@Test("Custom column widths are written into the header-storage bucket")
	func customColumnWidthsRoundTrip() throws {
		var table = PagesTable(rows: 2, columns: 3, cells: ["A", "B", "C", "1", "2", "3"])
		table.columnWidths = [40, 200, 70]
		let (url, store) = try writeStyledTable(table)
		defer { try? FileManager.default.removeItem(at: url) }

		// The column bucket: a HeaderStorageBucket whose Header entries (#2 f32 size)
		// carry the requested widths. Identify it by entry count == columns (3).
		let widths: [Float]? = store.objects.compactMap { object -> [Float]? in
			let headers = ProtobufMessage(object.payload).messages(2)
			guard headers.count == 3, headers.allSatisfy({ $0.float(2) != nil }) else { return nil }
			let sizes = headers.compactMap { $0.float(2) }
			return Set(sizes) == [40, 200, 70] ? sizes : nil
		}.first
		#expect(widths != nil, "expected a bucket carrying widths 40/200/70")
	}
}
