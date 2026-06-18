import SwiftTextIWA
import Foundation

public enum NumbersParserError: Error, CustomStringConvertible {
	case fileNotFound(URL)
	case notANumbersDocument(URL)

	public var description: String {
		switch self {
		case .fileNotFound(let url): return "File not found: \(url.path)"
		case .notANumbersDocument(let url): return "Not a Numbers document: \(url.path)"
		}
	}
}

/// Reads an Apple Numbers (`.numbers`) spreadsheet into a `NumbersDocument`.
///
/// The container, compression, and object-graph machinery are identical to Pages —
/// Numbers is the same IWA package format — so this reuses `IWAContainer`,
/// `IWAArchive`, and `IWAObjectStore` verbatim. What differs is navigation: a Numbers
/// document reaches its tables through `TN.DocumentArchive → sheets → TN.SheetArchive →
/// drawable_infos`, whereas Pages reaches them through the body text flow. From the
/// `TST.TableInfoArchive` down, both share `TSTTableReader`.
public struct NumbersParser {
	/// iWork persistence type numbers and field numbers used for navigation.
	///
	/// > Note: low type numbers are reused across the iWork apps (type 2 is
	/// > `TN.SheetArchive` in Numbers but `KN.ShowArchive` in Keynote), so these are only
	/// > meaningful in a `.numbers` document — which is exactly the context here.
	private enum Const {
		static let documentArchiveType: UInt64 = 1   // TN.DocumentArchive
		static let sheetArchiveType: UInt64 = 2       // TN.SheetArchive
		static let tableInfoType: UInt64 = 6000       // TST.TableInfoArchive
		static let documentSheetsField = 1            // TN.DocumentArchive.sheets (repeated ref)
		static let sheetNameField = 1                 // TN.SheetArchive.name
		static let sheetDrawablesField = 2            // TN.SheetArchive.drawable_infos (repeated ref)
		static let tableInfoModelField = 2            // TST.TableInfoArchive → TableModelArchive
		static let refIdentifierField = 1             // TSP.Reference.identifier
	}

	public init() {}

	public func readDocument(from url: URL) throws -> NumbersDocument {
		guard FileManager.default.fileExists(atPath: url.path) else {
			throw NumbersParserError.fileNotFound(url)
		}
		// Modern (iWork '13+) documents store content as Index/*.iwa objects.
		let entries = try IWAContainer.entries(at: url, prefix: "Index/", suffix: ".iwa")
		guard !entries.isEmpty else {
			// Legacy (iWork '09) documents store a single uncompressed index.xml instead,
			// mirroring how PagesParser falls back to PagesLegacyParser. Tables are decoded
			// by the shared IWALegacyTableReader (the same `<sf:tabular-model>` the legacy
			// Pages reader uses).
			if let indexXML = IWAContainer.data(at: url, named: "index.xml") {
				let tables = try IWALegacyTableReader.tables(fromIndexXML: indexXML)
				return NumbersDocument(sheets: tables.isEmpty ? [] : [NumbersDocument.Sheet(name: nil, tables: tables)])
			}
			throw NumbersParserError.notANumbersDocument(url)
		}

		var store = IWAObjectStore()
		for entry in entries {
			// Skip any entry that isn't a standard Snappy/Protobuf IWA file (e.g. the
			// collaboration/undo log), matching how the Pages reader loads its store.
			guard let objects = try? IWAArchive.objects(from: entry.data) else { continue }
			for object in objects { store.add(object) }
		}
		return Self.buildDocument(from: store)
	}

	static func buildDocument(from store: IWAObjectStore) -> NumbersDocument {
		func tables(onSheet sheet: IWAObject) -> [TSTTable] {
			ProtobufMessage(sheet.payload).messages(Const.sheetDrawablesField).compactMap { ref in
				guard let drawableID = ref.varint(Const.refIdentifierField),
				      let drawable = store.object(drawableID), drawable.type == Const.tableInfoType,
				      let modelID = ProtobufMessage(drawable.payload).message(Const.tableInfoModelField)?.varint(Const.refIdentifierField)
				else { return nil }
				return TSTTableReader.table(forModelID: modelID, store: store)
			}
		}
		func sheetName(_ sheet: IWAObject) -> String? {
			guard let raw = ProtobufMessage(sheet.payload).bytes(Const.sheetNameField) else { return nil }
			let name = String(decoding: raw, as: UTF8.self)
			return name.isEmpty ? nil : name
		}

		// Preferred: the document archive lists its sheets in display order; each sheet's
		// drawables include its tables.
		var sheets = [NumbersDocument.Sheet]()
		if let doc = store.objects(ofType: Const.documentArchiveType).first {
			for ref in ProtobufMessage(doc.payload).messages(Const.documentSheetsField) {
				guard let sheetID = ref.varint(Const.refIdentifierField),
				      let sheet = store.object(sheetID), sheet.type == Const.sheetArchiveType else { continue }
				sheets.append(.init(name: sheetName(sheet), tables: tables(onSheet: sheet)))
			}
		}

		// Fallback 1: enumerate sheet archives directly (no usable document archive).
		if sheets.allSatisfy({ $0.tables.isEmpty }) {
			let direct = store.objects(ofType: Const.sheetArchiveType).compactMap { sheet -> NumbersDocument.Sheet? in
				let found = tables(onSheet: sheet)
				return found.isEmpty ? nil : .init(name: sheetName(sheet), tables: found)
			}
			if !direct.isEmpty { sheets = direct }
		}

		// Fallback 2: every TableInfoArchive in the document, ungrouped. Resilient to
		// unexpected sheet structure — we still surface the tables we can decode.
		if sheets.allSatisfy({ $0.tables.isEmpty }) {
			let all = store.objects(ofType: Const.tableInfoType).compactMap { info -> TSTTable? in
				guard let modelID = ProtobufMessage(info.payload).message(Const.tableInfoModelField)?.varint(Const.refIdentifierField) else { return nil }
				return TSTTableReader.table(forModelID: modelID, store: store)
			}
			sheets = all.isEmpty ? [] : [.init(name: nil, tables: all)]
		}

		return NumbersDocument(sheets: sheets)
	}
}
