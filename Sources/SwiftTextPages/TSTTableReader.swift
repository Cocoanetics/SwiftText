import Foundation

/// A decoded iWork table: a rectangular grid of display strings plus per-column
/// alignment. The grid's first row is the table's first row (a header row, when the
/// table has one). Shared by Pages and Numbers — both store tables with the same
/// `TST` ("Tabular Spreadsheet Tables") model, so the same decoder serves both.
public struct TSTTable: Sendable, Equatable, Codable {
	public enum Alignment: String, Sendable, Equatable, Codable { case left, center, right }

	/// Row-major cell values. `cells[0]` is the first table row.
	public var cells: [[String]]
	/// One entry per column.
	public var columnAlignments: [Alignment]

	public var rows: Int { cells.count }
	public var columns: Int { cells.first?.count ?? 0 }

	public init(cells: [[String]], columnAlignments: [Alignment]) {
		self.cells = cells
		self.columnAlignments = columnAlignments
	}
}

/// Decodes a `TST.TableModelArchive` (and the `DataStore` / tile / cell-buffer chain
/// beneath it) into a `TSTTable` of *frozen* cell values — the cached formula result
/// iWork stores in each cell, so the table reads as static text with no recalculation.
///
/// This is the format-neutral half of iWork table reading. Navigation *to* the model
/// differs per app — Pages reaches it through a text-flow drawable attachment, Numbers
/// through a sheet's drawables — but `model → DataStore → tiles → cells` is identical,
/// which is why this lives apart from any one app's parser.
///
/// > Note: a near-identical decode currently also lives inline in `PagesParser`
/// > (`tableGrid(forAttachment:store:)`). That path is test-covered and predates this
/// > extraction; converging it onto this reader is a deliberate, separate follow-up so
/// > the Pages tests gate the change.
enum TSTTableReader {
	/// Field numbers and cell-buffer byte offsets for the `TST` table model. Mirrors the
	/// documented constants in `PagesParser.IWork`; kept here so the reader is
	/// self-contained and reusable across iWork apps.
	private enum Const {
		static let tableModelType: UInt64 = 6001
		static let referenceIdentifierField = 1
		static let tableRowCountField = 6
		static let tableColumnCountField = 7
		static let tableDataStoreField = 4

		static let dataStoreTilesField = 3
		static let dataStoreStringTableField = 4
		static let dataStoreStyleTableField = 5
		static let dataStoreRichTextTableField = 17

		static let tileStorageTileField = 1
		static let tileStorageTileRefField = 2
		static let tileRowInfosField = 5
		static let tileRowIndexField = 1
		// Modern ("BNC") cell storage: wide buffer/offsets, decimal128 numbers at byte 12.
		static let tileCellBufferField = 6
		static let tileCellOffsetsField = 7
		static let modernCellValueOffset = 12
		// Pre-BNC cell storage (Numbers ≤ ~2016, storage version ≤ 4): narrow buffer/
		// offsets, `double` numbers at byte 16.
		static let tileCellBufferPreBncField = 3
		static let tileCellOffsetsPreBncField = 4
		static let preBncCellValueOffset = 16

		static let dataListEntryField = 3
		static let dataListKeyField = 1
		static let dataListStringField = 3
		static let styleTableRefField = 4
		static let dataListWrapperRefField = 9

		static let storageArchiveType: UInt64 = 2001

		static let cellKeyByteOffset = 12
		static let cellTypeByteOffset = 1
		static let cellFlagsByteOffset = 8
		static let cellStyleKeyBit: UInt8 = 0x40
		static let cellStyleKeyByteOffset = 16

		static let cellNumberType: UInt8 = 0x02
		static let cellDateType: UInt8 = 0x05
		static let cellDurationType: UInt8 = 0x06
		static let cellBoolType: UInt8 = 0x07
		static let cellRichType: UInt8 = 0x09

		static let paragraphPropertiesField = 12
		static let paragraphAlignmentField = 1
		static let storageTextField = 3
	}

	/// Decodes the table whose `TableModelArchive` has the given object id.
	///
	/// - Parameters:
	///   - richText: renders a rich-text cell's `TSWP.StorageArchive` to a display
	///     string. Defaults to the storage's plain text; a caller with an emphasis
	///     renderer (e.g. Pages) can pass one that emits inline Markdown instead.
	///   - richAlignment: resolves a rich cell's column alignment from its own
	///     paragraph style. Defaults to `nil` (left).
	static func table(
		forModelID modelID: UInt64,
		store: IWAObjectStore,
		richText: (IWAObject, IWAObjectStore) -> String = { storage, _ in plainText(of: storage) },
		richAlignment: (IWAObject, IWAObjectStore) -> TSTTable.Alignment? = { _, _ in nil }
	) -> TSTTable? {
		guard let model = store.object(modelID), model.type == Const.tableModelType else { return nil }
		let modelMessage = ProtobufMessage(model.payload)
		let rows = Int(modelMessage.varint(Const.tableRowCountField) ?? 0)
		let columns = Int(modelMessage.varint(Const.tableColumnCountField) ?? 0)
		guard rows > 0, columns > 0, let dataStore = modelMessage.message(Const.tableDataStoreField) else { return nil }

		// stringTable → cell-string DataList → key → string.
		var stringsByKey = [UInt64: String]()
		if let stringTableID = dataStore.message(Const.dataStoreStringTableField)?.varint(Const.referenceIdentifierField),
		   let dataList = store.object(stringTableID) {
			for entry in ProtobufMessage(dataList.payload).messages(Const.dataListEntryField) {
				if let key = entry.varint(Const.dataListKeyField), let string = entry.bytes(Const.dataListStringField) {
					stringsByKey[key] = String(decoding: string, as: UTF8.self)
				}
			}
		}

		// styleTable → key → cell paragraph style id (for alignment).
		var styleIDByKey = [UInt64: UInt64]()
		if let styleTableID = dataStore.message(Const.dataStoreStyleTableField)?.varint(Const.referenceIdentifierField),
		   let styleList = store.object(styleTableID) {
			for entry in ProtobufMessage(styleList.payload).messages(Const.dataListEntryField) {
				if let key = entry.varint(Const.dataListKeyField),
				   let styleID = entry.message(Const.styleTableRefField)?.varint(Const.referenceIdentifierField) {
					styleIDByKey[key] = styleID
				}
			}
		}
		func alignment(forStyleKey key: UInt64) -> TSTTable.Alignment {
			guard let styleID = styleIDByKey[key], let style = store.object(styleID),
			      let value = ProtobufMessage(style.payload).message(Const.paragraphPropertiesField)?.varint(Const.paragraphAlignmentField) else { return .left }
			switch value {
			case 1: return .right
			case 2: return .center
			default: return .left
			}
		}

		// rich_text_table → key → cell text StorageArchive id. Each entry's reference is
		// usually a wrapper around the 2001 storage; a direct storage reference is also
		// tolerated for resilience against other writers.
		var richStorageByKey = [UInt64: UInt64]()
		if let richTableID = dataStore.message(Const.dataStoreRichTextTableField)?.varint(Const.referenceIdentifierField),
		   let richList = store.object(richTableID) {
			for entry in ProtobufMessage(richList.payload).messages(Const.dataListEntryField) {
				guard let key = entry.varint(Const.dataListKeyField),
				      let refID = entry.message(Const.dataListWrapperRefField)?.varint(Const.referenceIdentifierField),
				      let ref = store.object(refID) else { continue }
				let storageID = ref.type == Const.storageArchiveType
					? refID
					: ProtobufMessage(ref.payload).message(Const.referenceIdentifierField)?.varint(Const.referenceIdentifierField)
				if let storageID { richStorageByKey[key] = storageID }
			}
		}

		// tiles → the single tile holding all rows → per-row cell keys.
		guard let tileID = dataStore.message(Const.dataStoreTilesField)?
				.message(Const.tileStorageTileField)?
				.message(Const.tileStorageTileRefField)?
				.varint(Const.referenceIdentifierField),
		      let tile = store.object(tileID) else { return nil }

		var grid = Array(repeating: Array(repeating: "", count: columns), count: rows)
		var columnAlignments = Array(repeating: TSTTable.Alignment.left, count: columns)
		// Per-column body-cell census, for the implicit alignment iWork applies by value
		// type: a column whose body cells are all numeric/date (no text) right-aligns by
		// default unless an explicit alignment override is set.
		var columnHasNumber = Array(repeating: false, count: columns)
		var columnHasText = Array(repeating: false, count: columns)
		var columnExplicitlyAligned = Array(repeating: false, count: columns)
		for rowInfo in ProtobufMessage(tile.payload).messages(Const.tileRowInfosField) {
			guard let rowIndex = rowInfo.varint(Const.tileRowIndexField).map(Int.init), rowIndex < rows else { continue }
			// A row carries its cells in one of two storage generations: prefer the modern
			// ("BNC") buffer, fall back to the older pre-BNC buffer. They differ in where a
			// cell's key/value sit and in how numbers are encoded (decimal128 vs. `double`).
			let buffer: [UInt8], offsets: [UInt8], modern: Bool
			if let b = rowInfo.bytes(Const.tileCellBufferField), let o = rowInfo.bytes(Const.tileCellOffsetsField) {
				buffer = b; offsets = o; modern = true
			} else if let b = rowInfo.bytes(Const.tileCellBufferPreBncField), let o = rowInfo.bytes(Const.tileCellOffsetsPreBncField) {
				buffer = b; offsets = o; modern = false
			} else { continue }
			let cellStarts = cellOffsets(offsets)
			let sortedStarts = cellStarts.filter { $0 >= 0 }.sorted()
			for (column, start) in cellStarts.enumerated() where column < columns {
				guard start >= 0 else { continue }
				// The cell record runs to the next populated cell (or the buffer's end).
				let cellEnd = sortedStarts.first(where: { $0 > start }) ?? buffer.count
				// Modern: key and value both at byte 12 (decimal128 numbers are 16 bytes).
				// Pre-BNC: the string key is at byte 16, and the 8-byte `double` value sits
				// 12 bytes before the record's end (value + 4 trailing format bytes), which
				// tracks the variable per-cell field layout instead of a fixed offset.
				let keyOffset = start + (modern ? Const.modernCellValueOffset : Const.preBncCellValueOffset)
				let valueOffset = modern ? start + Const.modernCellValueOffset : cellEnd - 12
				guard keyOffset + 4 <= buffer.count, valueOffset >= start else { continue }
				let key = UInt64(buffer[keyOffset]) | UInt64(buffer[keyOffset + 1]) << 8 | UInt64(buffer[keyOffset + 2]) << 16 | UInt64(buffer[keyOffset + 3]) << 24
				let typeByte = start + Const.cellTypeByteOffset < buffer.count ? buffer[start + Const.cellTypeByteOffset] : 0
				if modern, typeByte == Const.cellRichType, let storageID = richStorageByKey[key], let storage = store.object(storageID) {
					grid[rowIndex][column] = richText(storage, store)
					if rowIndex >= 1, let aligned = richAlignment(storage, store) {
						columnAlignments[column] = aligned
						columnExplicitlyAligned[column] = true
					}
				} else if let frozen = frozenValue(buffer, valueAt: valueOffset, type: typeByte, numberIsDecimal128: modern) {
					grid[rowIndex][column] = frozen
				} else if let string = stringsByKey[key] {
					grid[rowIndex][column] = string
				}
				// Census body cells by value type for the implicit-alignment default.
				if rowIndex >= 1 {
					switch typeByte {
					case Const.cellNumberType, Const.cellDateType, Const.cellDurationType, Const.cellBoolType:
						columnHasNumber[column] = true
					default:
						if !grid[rowIndex][column].isEmpty { columnHasText[column] = true }
					}
				}
				// Column alignment comes from body cells: a styled cell (flag bit set)
				// carries a styleTable key at byte 16. Modern storage only — in pre-BNC the
				// value itself lives at byte 16, so we lean on the implicit default instead.
				if modern, rowIndex >= 1, start + Const.cellFlagsByteOffset < buffer.count,
				   buffer[start + Const.cellFlagsByteOffset] & Const.cellStyleKeyBit != 0,
				   start + Const.cellStyleKeyByteOffset + 4 <= buffer.count {
					let styleBase = start + Const.cellStyleKeyByteOffset
					let styleKey = UInt64(buffer[styleBase]) | UInt64(buffer[styleBase + 1]) << 8 | UInt64(buffer[styleBase + 2]) << 16 | UInt64(buffer[styleBase + 3]) << 24
					columnAlignments[column] = alignment(forStyleKey: styleKey)
					columnExplicitlyAligned[column] = true
				}
			}
		}
		// Implicit default: a column of purely numeric/date values right-aligns (as iWork
		// displays it) unless an explicit alignment override is present.
		for column in 0..<columns where !columnExplicitlyAligned[column] && columnHasNumber[column] && !columnHasText[column] {
			columnAlignments[column] = .right
		}
		return TSTTable(cells: grid, columnAlignments: columnAlignments)
	}

	// MARK: - Cell value decoding

	/// The frozen (cached) value of a numeric / date / bool / duration cell rendered as
	/// static text — the displayed formula result, no recalculation. Returns `nil` for
	/// text/rich cells (which carry a string-table or rich-text key the caller resolves).
	///
	/// - Parameters:
	///   - o: byte offset of the cell's value within `b` (12 for modern storage, 16 for
	///     pre-BNC).
	///   - numberIsDecimal128: modern storage encodes numbers as decimal128; pre-BNC
	///     storage encodes them as a `double`. Dates, durations, and bools are `double`
	///     in both.
	static func frozenValue(_ b: [UInt8], valueAt o: Int, type: UInt8, numberIsDecimal128: Bool) -> String? {
		func readDouble(_ off: Int) -> Double? {
			guard off + 8 <= b.count else { return nil }
			var bits: UInt64 = 0; for k in 0..<8 { bits |= UInt64(b[off + k]) << (8 * k) }
			return Double(bitPattern: bits)
		}
		switch type {
		case Const.cellNumberType:
			if numberIsDecimal128 { return decimal128String(b, at: o) }
			guard let v = readDouble(o) else { return nil }
			return formatDouble(v)
		case Const.cellDateType:
			guard let seconds = readDouble(o) else { return nil }
			let formatter = DateFormatter()
			formatter.dateFormat = "yyyy-MM-dd HH:mm"
			formatter.timeZone = TimeZone(identifier: "UTC")
			return formatter.string(from: Date(timeIntervalSinceReferenceDate: seconds))
		case Const.cellBoolType:
			guard let v = readDouble(o) else { return nil }
			return v != 0 ? "true" : "false"
		case Const.cellDurationType:
			guard let s = readDouble(o) else { return nil }
			return "\(Int(s.rounded()))s"
		default:
			return nil
		}
	}

	/// Renders a pre-BNC `double` cell value as text. Whole numbers print without a
	/// fractional part; other values use 12 significant digits, which collapses the
	/// binary-`double` representation noise that Numbers itself hides on display (e.g.
	/// `12040.079999999998` → `12040.08`). Subnormal/non-finite results — the signature of
	/// a misread cell — render blank rather than as an absurd value.
	static func formatDouble(_ v: Double) -> String {
		guard v.isFinite, !v.isSubnormal else { return "" }
		if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
		return String(format: "%.12g", v)
	}

	/// Decodes an IEEE 754-2008 decimal128 (BID) at `o` (16 bytes, little-endian) to an
	/// exact decimal string. Handles the common small-coefficient form (≤ 64-bit
	/// coefficient); returns `nil` for the rarer large form so the caller falls back.
	static func decimal128String(_ b: [UInt8], at o: Int) -> String? {
		guard o + 16 <= b.count else { return nil }
		func u64(_ off: Int) -> UInt64 { var v: UInt64 = 0; for k in 0..<8 { v |= UInt64(b[off + k]) << (8 * k) }; return v }
		let lo = u64(o), hi = u64(o + 8)
		let sign = (hi >> 63) & 1
		guard (hi >> 61) & 0x3 != 0x3 else { return nil }     // large-coefficient/special form
		let exponent = Int((hi >> 49) & 0x3FFF) - 6176
		guard hi & 0x1_FFFF_FFFF_FFFF == 0 else { return nil } // >64-bit coefficient
		var digits = String(lo)
		let result: String
		if exponent >= 0 {
			result = digits + String(repeating: "0", count: min(exponent, 40))
		} else {
			let frac = -exponent
			if digits.count <= frac { digits = String(repeating: "0", count: frac - digits.count + 1) + digits }
			let split = digits.index(digits.endIndex, offsetBy: -frac)
			let intPart = String(digits[..<split])
			var fracPart = String(digits[split...])
			while fracPart.hasSuffix("0") { fracPart.removeLast() }
			result = fracPart.isEmpty ? intPart : "\(intPart).\(fracPart)"
		}
		return sign == 1 && result != "0" ? "-" + result : result
	}

	/// Parses a tile row's `u16` cell-offset array (little-endian): one entry per column,
	/// each the byte offset of that column's cell into the cell buffer. The `0xFFFF`
	/// sentinel marks an *empty* cell (returned here as `-1`) — it is **not** an
	/// end-of-row terminator, so the array continues past it. Treating it as a terminator
	/// (as a naive reader does) silently drops every cell that follows a gap, which is
	/// common in spreadsheets (e.g. a total in column C with column B left blank).
	static func cellOffsets(_ bytes: [UInt8]) -> [Int] {
		var offsets = [Int]()
		var i = 0
		while i + 1 < bytes.count {
			let value = Int(bytes[i]) | Int(bytes[i + 1]) << 8
			offsets.append(value == 0xFFFF ? -1 : value)
			i += 2
		}
		return offsets
	}

	/// Concatenates a `TSWP.StorageArchive`'s repeated text chunks (`#3`) into its plain
	/// text — the default rendering for rich-text cells.
	static func plainText(of storage: IWAObject) -> String {
		let message = ProtobufMessage(storage.payload)
		var text = ""
		for chunk in message.allBytes(Const.storageTextField) {
			text += String(decoding: chunk, as: UTF8.self)
		}
		return text
	}
}
