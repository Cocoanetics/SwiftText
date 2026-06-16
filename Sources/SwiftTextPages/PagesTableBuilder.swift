import Foundation

/// A table destined for native iWork (`TST`) rendering: a rectangular grid of
/// already-flattened cell strings, row-major, with the first row as the header.
struct PagesTable {
	let rows: Int
	let columns: Int
	/// `rows * columns` cell strings, row-major (row 0 = header row).
	let cells: [String]
}

/// The package-level artifacts for injecting native tables into the blank template.
struct PagesTableArtifacts {
	/// Record-stream bytes to append to an existing base component (keyed by package path).
	var appendsByFile: [String: [UInt8]] = [:]
	/// Complete new `.iwa` files to add to the package (keyed by package path).
	var newFiles: [String: [UInt8]] = [:]
	/// The attachment (type 2003) object id each table anchors to, in table order.
	var attachmentIDs: [UInt64] = []
	/// The number of tables built — drives how many id-offset clones of the captured
	/// `Index/Tables/*` `ComponentInfo`s (and base cross-references) the writer adds.
	var tableCount = 0
	/// Highest object id used across all injected tables.
	var maxObjectID: UInt64 = 0
}

/// Builds the native-table object set for a document by adapting the captured
/// single-table template (`PagesTableTemplate`) to each table's dimensions and
/// cell content.
///
/// The grid extent is governed by `base_column_row_uids` (column/row UID counts);
/// the tile, cell-string list, header buckets, model counts, and frame are all
/// regenerated to match. Every other captured object is cloned verbatim. The full
/// recipe is recorded in `PAGES_WRITING.md`.
enum PagesTableBuilder {
	/// Default cell metrics captured from the template (points).
	private static let columnWidth: Float = 120.38605
	private static let rowHeight: Float = 22.73
	/// Tiles reserve a fixed 256-column offset capacity; offset arrays are 510 bytes.
	private static let offsetArrayBytes = 510

	enum BuildError: Error { case missingTemplateRecord(UInt64) }

	/// Per-table object-id offset. The captured ids span ~1732664–1734988 (< 2324);
	/// a 4096 step keeps each table's ids disjoint and below 2^21, so every offset id
	/// still encodes as a 3-byte varint (no payload-length changes when re-id-ing).
	static let idOffsetStep: UInt64 = 4096
	/// The set of captured table object ids — references to these are the ones that
	/// get offset when relocating a table; references to base-document objects don't.
	static let capturedIDs: Set<UInt64> = Set(PagesTableTemplate.records.map(\.id))

	/// Builds artifacts for the given tables. The first table reuses the captured
	/// object ids; each subsequent table relocates the whole object set by a fixed
	/// id offset (and its `Index/Tables/*` files get id-suffixed names + their own
	/// `ComponentInfo`), so a document can carry any number of native tables.
	static func build(_ tables: [PagesTable]) throws -> PagesTableArtifacts {
		var artifacts = PagesTableArtifacts()
		var appendStreams: [String: [UInt8]] = [:]

		let records = PagesTableTemplate.records
		func record(_ id: UInt64) throws -> [UInt8] {
			guard let entry = records.first(where: { $0.id == id }),
			      let data = Data(base64Encoded: entry.base64) else {
				throw BuildError.missingTemplateRecord(id)
			}
			return [UInt8](data)
		}

		for (tableIndex, table) in tables.enumerated() {
			let offset = UInt64(tableIndex) * idOffsetStep
			let R = table.rows, C = table.columns
			// Regenerate the dimension-dependent payloads (with base-table references,
			// offset below alongside every cloned object).
			let rewritten: [UInt64: [UInt8]] = [
				PagesTableTemplate.columnRowUIDsID: buildColumnRowUIDs(rows: R, columns: C),
				PagesTableTemplate.tileID: buildTile(rows: R, columns: C),
				PagesTableTemplate.cellStringsID: buildCellStrings(table.cells),
				PagesTableTemplate.modelID: patchModel(try record(PagesTableTemplate.modelID).payloadOnly, rows: R, columns: C, name: "Table \(tableIndex + 1)"),
				PagesTableTemplate.rowHeadersBucketID: buildBucket(try record(PagesTableTemplate.rowHeadersBucketID).payloadOnly, count: R, otherDimension: C, size: rowHeight),
				PagesTableTemplate.columnHeadersBucketID: buildBucket(try record(PagesTableTemplate.columnHeadersBucketID).payloadOnly, count: C, otherDimension: R, size: columnWidth),
				PagesTableTemplate.tableInfoID: hideTitleAndCaption(try record(PagesTableTemplate.tableInfoID).payloadOnly),
			]

			for entry in records {
				artifacts.maxObjectID = max(artifacts.maxObjectID, entry.id + offset)
				// `Index/Metadata.iwa` (PackageMetadata + shared-object map) is supplied
				// wholesale from the captured template, so skip its delta records here —
				// appending them would duplicate the shared-object-map object.
				if entry.file == "Index/Metadata.iwa" { continue }
				let recordBytes = try record(entry.id)
				let payload = rewritten[entry.id] ?? recordBytes.payloadOnly
				let finalRecord = relocateRecord(recordBytes, newPayload: payload, offset: offset)
				if entry.file.hasPrefix("Index/Tables/") {
					let path = offset == 0 ? entry.file : relocatedTablePath(entry.file, newID: entry.id + offset)
					artifacts.newFiles[path] = [UInt8](IWAArchive.encode(stream: finalRecord))
				} else {
					appendStreams[entry.file, default: []].append(contentsOf: finalRecord)
				}
			}
			artifacts.attachmentIDs.append(PagesTableTemplate.attachmentID + offset)
		}
		artifacts.appendsByFile = appendStreams
		artifacts.tableCount = tables.count
		return artifacts
	}

	// MARK: Dimension-object payloads (see PAGES_WRITING.md for the byte format)

	/// `base_column_row_uids` — C column UIDs (#1) + R row UIDs (#4) drive the grid
	/// extent. Orderings (#2/#3 columns, #5/#6 rows) are identity. UIDs are fresh
	/// unique 64-bit pairs (cells reference columns/rows positionally, not by UID).
	static func buildColumnRowUIDs(rows R: Int, columns C: Int) -> [UInt8] {
		func uid(_ a: UInt64, _ b: UInt64) -> [UInt8] {
			var w = ProtobufWriter(); w.varintField(1, a); w.varintField(2, b); return w.bytes
		}
		var w = ProtobufWriter()
		for c in 0..<C { w.bytesField(1, uid(0x5000_0000_0000_0001 &+ UInt64(c) &* 0x1_0000, 0x0300_0000_0000_0007)) }
		for c in 0..<C { w.varintField(2, UInt64(c)) }
		for c in 0..<C { w.varintField(3, UInt64(c)) }
		for r in 0..<R { w.bytesField(4, uid(0x6000_0000_0000_0001 &+ UInt64(r) &* 0x1_0000, 0x0300_0000_0000_0009)) }
		for r in 0..<R { w.varintField(5, UInt64(r)) }
		for r in 0..<R { w.varintField(6, UInt64(r)) }
		return w.bytes
	}

	/// `TST.Tile` — top `#4` numrows = R, `#6`/per-row `#5` are storage_version (=5,
	/// constant — NOT counts). One `TileRowInfo` (`#5`) per row with C 28/24-byte
	/// string cells whose `u32@12` is the cell-string key (`r*C + c + 1`).
	static func buildTile(rows R: Int, columns C: Int) -> [UInt8] {
		var w = ProtobufWriter()
		w.varintField(1, 0); w.varintField(2, 0); w.varintField(3, 0)   // maxColumn/maxRow/numCells
		w.varintField(4, UInt64(R))                                     // numrows
		for r in 0..<R { w.bytesField(5, tileRow(r, columns: C)) }
		w.varintField(6, 5)                                             // storage_version (constant)
		w.varintField(7, 1)                                             // last_saved_in_BNC
		return w.bytes
	}

	private static func tileRow(_ row: Int, columns C: Int) -> [UInt8] {
		let columnMeta = (0..<C).flatMap { _ -> [UInt8] in [0x04, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] }
		let metaOffsets = (0..<C).map { $0 * 12 }
		var cells = [UInt8]()
		var cellStarts = [Int]()
		for c in 0..<C {
			cellStarts.append(cells.count)
			let key = row * C + c + 1
			cells.append(contentsOf: row == 0 ? headerCell(key: key) : bodyCell(key: key))
		}
		var w = ProtobufWriter()
		w.varintField(1, UInt64(row))                       // tile_row_index
		w.varintField(2, UInt64(C))                         // cell_count
		w.bytesField(3, columnMeta)                         // cell_storage_buffer_pre_bnc
		w.bytesField(4, offsetArray(metaOffsets))           // cell_offsets_pre_bnc
		w.varintField(5, 5)                                 // storage_version (constant)
		w.bytesField(6, cells)                              // cell_storage_buffer
		w.bytesField(7, offsetArray(cellStarts))            // cell_offsets
		return w.bytes
	}

	private static func headerCell(key: Int) -> [UInt8] {
		[0x05, 0x03, 0, 0, 0, 0, 0, 0] + [0x48, 0x10, 0x02, 0x00] + u32le(key) + [0x01, 0, 0, 0, 0x05, 0, 0, 0, 0x01, 0, 0, 0]
	}
	private static func bodyCell(key: Int) -> [UInt8] {
		[0x05, 0x03, 0, 0, 0, 0, 0, 0] + [0x08, 0x10, 0x02, 0x00] + u32le(key) + [0x05, 0, 0, 0, 0x01, 0, 0, 0]
	}
	private static func u32le(_ v: Int) -> [UInt8] {
		[UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
	}
	/// A fixed 510-byte uint16 offset array, 0xFFFF-padded after the live entries.
	private static func offsetArray(_ offsets: [Int]) -> [UInt8] {
		var a = [UInt8]()
		for o in offsets { a.append(UInt8(o & 0xff)); a.append(UInt8((o >> 8) & 0xff)) }
		while a.count < offsetArrayBytes { a.append(0xff); a.append(0xff) }
		return Array(a.prefix(offsetArrayBytes))
	}

	/// `TST.TableDataList` cell-string store: `#1` listid=1, `#2` count=maxKey+1,
	/// repeated `#3 { #1 key, #2 1, #3 string }`. Keys are `r*C + c + 1`, row-major.
	static func buildCellStrings(_ strings: [String]) -> [UInt8] {
		var w = ProtobufWriter()
		w.varintField(1, 1)
		w.varintField(2, UInt64(strings.count + 1))
		for (index, string) in strings.enumerated() {
			var entry = ProtobufWriter()
			entry.varintField(1, UInt64(index + 1))
			entry.varintField(2, 1)
			entry.stringField(3, string)
			w.bytesField(3, entry.bytes)
		}
		return w.bytes
	}

	/// `TableModelArchive`: set `#6` rows, `#7` columns, `#8` table name, `#9` header
	/// rows = 1, `#10` header columns = 0 (Markdown has a header row, not a column),
	/// `#22` table_name_enabled = 0 (Markdown tables have no visible title).
	static func patchModel(_ payload: [UInt8], rows R: Int, columns C: Int, name: String) -> [UInt8] {
		let model = ProtobufMessage(payload)
		var w = ProtobufWriter()
		var wroteHeaderColumns = false, wroteNameEnabled = false
		for field in model.fields {
			switch field.number {
			case 6: w.varintField(6, UInt64(R))
			case 7: w.varintField(7, UInt64(C))
			case 8: w.stringField(8, name)
			case 9: w.varintField(9, 1)
			case 10: w.varintField(10, 0); wroteHeaderColumns = true
			case 22: w.varintField(22, 0); wroteNameEnabled = true
			default: w.append(field)
			}
		}
		if !wroteHeaderColumns { w.varintField(10, 0) }
		if !wroteNameEnabled { w.varintField(22, 0) }
		return w.bytes
	}

	/// `TableInfoArchive` (6000): hide the table title and caption by setting the
	/// `super` (`TSD.DrawableArchive`) `#12` title_hidden and `#13` caption_hidden —
	/// Markdown tables carry neither. Other drawable fields (geometry, the title and
	/// caption storages) are preserved.
	static func hideTitleAndCaption(_ payload: [UInt8]) -> [UInt8] {
		let info = ProtobufMessage(payload)
		var writer = ProtobufWriter()
		for field in info.fields {
			guard field.number == 1, case .lengthDelimited(let drawable) = field.value else { writer.append(field); continue }
			var drawableWriter = ProtobufWriter()
			var wroteTitle = false, wroteCaption = false
			for drawableField in ProtobufMessage(drawable).fields {
				switch drawableField.number {
				case 12: drawableWriter.varintField(12, 1); wroteTitle = true
				case 13: drawableWriter.varintField(13, 1); wroteCaption = true
				default: drawableWriter.append(drawableField)
				}
			}
			if !wroteTitle { drawableWriter.varintField(12, 1) }
			if !wroteCaption { drawableWriter.varintField(13, 1) }
			writer.bytesField(1, drawableWriter.bytes)
		}
		return writer.bytes
	}

	/// `HeaderStorageBucket` (row heights / column widths): `count` `Header`s
	/// `{ #1 index, #2 f32 size, #3 0, #4 otherDimension }`. The entry count is one
	/// of the grid dimensions; reuses the captured default size for every entry.
	static func buildBucket(_ payload: [UInt8], count: Int, otherDimension: Int, size: Float) -> [UInt8] {
		var w = ProtobufWriter()
		w.varintField(1, 1)                                  // bucketHashFunction
		for index in 0..<count {
			var header = ProtobufWriter()
			header.varintField(1, UInt64(index))
			header.fixed32Field(2, size.bitPattern)
			header.varintField(3, 0)
			header.varintField(4, UInt64(otherDimension))
			w.bytesField(2, header.bytes)
		}
		return w.bytes
	}

	// MARK: Record relocation (re-id-ing a table's objects)

	/// Re-emits an object record with its payload replaced and the whole object
	/// relocated by `offset`: the object's own id, its `MessageInfo.object_references`
	/// (and `FieldInfo` reference paths), and every reference inside the payload that
	/// targets a captured table object are shifted by `offset`. With `offset == 0`
	/// this is a payload swap that preserves the `ArchiveInfo` exactly. Offset ids
	/// stay 3-byte varints (see ``idOffsetStep``), so lengths never change.
	static func relocateRecord(_ recordBytes: [UInt8], newPayload payload: [UInt8], offset: UInt64) -> [UInt8] {
		let newPayload = offset == 0 ? payload : offsetReferences(payload, by: offset)
		var pos = 0
		func readVarint() -> UInt64 {
			var shift = UInt64(0), result = UInt64(0)
			while pos < recordBytes.count { let b = recordBytes[pos]; pos += 1; result |= UInt64(b & 0x7F) << shift; if b & 0x80 == 0 { break }; shift += 7 }
			return result
		}
		let aiLength = Int(readVarint())
		let archiveInfo = ProtobufMessage(Array(recordBytes[pos..<pos + aiLength]))
		var aiWriter = ProtobufWriter()
		for field in archiveInfo.fields {
			switch field.number {
			case 1 where offset != 0:
				// The object's own identifier.
				if case .varint(let id) = field.value { aiWriter.varintField(1, shifted(id, by: offset)) } else { aiWriter.append(field) }
			case 2:
				guard case .lengthDelimited(let messageInfo) = field.value else { aiWriter.append(field); continue }
				aiWriter.bytesField(2, relocateMessageInfo(messageInfo, payloadLength: newPayload.count, offset: offset))
			default:
				aiWriter.append(field)
			}
		}
		var out = ProtobufWriter.varint(UInt64(aiWriter.bytes.count))
		out.append(contentsOf: aiWriter.bytes)
		out.append(contentsOf: newPayload)
		return out
	}

	/// Rebuilds a `MessageInfo`: sets the payload length (#3) and, when relocating,
	/// shifts the packed `object_references` (#5) and each `FieldInfo`'s (#4) inline
	/// reference list. Other fields (type, version, data_references) are preserved.
	private static func relocateMessageInfo(_ messageInfo: [UInt8], payloadLength: Int, offset: UInt64) -> [UInt8] {
		var writer = ProtobufWriter()
		for field in ProtobufMessage(messageInfo).fields {
			switch field.number {
			case 3:
				writer.varintField(3, UInt64(payloadLength))
			case 4 where offset != 0:
				guard case .lengthDelimited(let fieldInfo) = field.value else { writer.append(field); continue }
				writer.bytesField(4, relocateFieldInfo(fieldInfo, offset: offset))
			case 5 where offset != 0:
				guard case .lengthDelimited(let refs) = field.value else { writer.append(field); continue }
				writer.bytesField(5, offsetPackedVarints(refs, by: offset))
			default:
				writer.append(field)
			}
		}
		return writer.bytes
	}

	/// Shifts a `FieldInfo`'s inline reference list (its field 4, packed varints).
	private static func relocateFieldInfo(_ fieldInfo: [UInt8], offset: UInt64) -> [UInt8] {
		var writer = ProtobufWriter()
		for field in ProtobufMessage(fieldInfo).fields {
			if field.number == 4, case .lengthDelimited(let refs) = field.value {
				writer.bytesField(4, offsetPackedVarints(refs, by: offset))
			} else {
				writer.append(field)
			}
		}
		return writer.bytes
	}

	/// Shifts every captured-table id in a packed-varint reference list by `offset`.
	private static func offsetPackedVarints(_ bytes: [UInt8], by offset: UInt64) -> [UInt8] {
		var out = [UInt8]()
		var pos = 0
		while pos < bytes.count {
			var shift = UInt64(0), value = UInt64(0)
			while pos < bytes.count { let b = bytes[pos]; pos += 1; value |= UInt64(b & 0x7F) << shift; if b & 0x80 == 0 { break }; shift += 7 }
			out.append(contentsOf: ProtobufWriter.varint(shifted(value, by: offset)))
		}
		return out
	}

	/// Recursively shifts every captured-table id reference in a protobuf payload by
	/// `offset`. A field is only re-encoded if its subtree actually contains a
	/// captured-id reference; otherwise the original bytes are kept verbatim. This is
	/// essential: a string or raw field (a UUID, "Table 1", a packed buffer) can
	/// happen to parse as a message, and blindly re-encoding it would corrupt it —
	/// returning the original bytes unless a reference was found avoids that.
	static func offsetReferences(_ bytes: [UInt8], by offset: UInt64) -> [UInt8] {
		offsetReferencesIfChanged(bytes, by: offset).bytes
	}

	private static func offsetReferencesIfChanged(_ bytes: [UInt8], by offset: UInt64) -> (bytes: [UInt8], changed: Bool) {
		guard let fields = strictMessageFields(bytes) else { return (bytes, false) }
		var writer = ProtobufWriter()
		var changed = false
		for field in fields {
			switch field.value {
			case .varint(let value):
				let shiftedValue = shifted(value, by: offset)
				if shiftedValue != value { changed = true }
				writer.varintField(field.number, shiftedValue)
			case .lengthDelimited(let sub):
				let result = offsetReferencesIfChanged(sub, by: offset)
				if result.changed { changed = true }
				writer.bytesField(field.number, result.bytes)
			case .fixed32(let raw):
				writer.appendFixed32(field.number, raw)
			case .fixed64:
				writer.append(field)
			}
		}
		return changed ? (writer.bytes, true) : (bytes, false)
	}

	private static func shifted(_ id: UInt64, by offset: UInt64) -> UInt64 {
		capturedIDs.contains(id) ? id + offset : id
	}

	/// Parses `bytes` as a protobuf message, returning its fields only if the whole
	/// buffer is consumed with valid wire types — so raw (non-protobuf) length-
	/// delimited fields are recognized and skipped rather than corrupted.
	private static func strictMessageFields(_ bytes: [UInt8]) -> [ProtobufField]? {
		guard !bytes.isEmpty else { return nil }
		var fields = [ProtobufField]()
		var pos = 0
		func readVarint() -> UInt64? {
			var shift = UInt64(0), result = UInt64(0)
			while pos < bytes.count {
				let b = bytes[pos]; pos += 1
				result |= UInt64(b & 0x7F) << shift
				if b & 0x80 == 0 { return result }
				shift += 7
				if shift >= 64 { return nil }
			}
			return nil
		}
		while pos < bytes.count {
			guard let key = readVarint() else { return nil }
			let number = Int(key >> 3)
			guard number > 0 else { return nil }
			switch key & 0x07 {
			case 0:
				guard let value = readVarint() else { return nil }
				fields.append(ProtobufField(number: number, value: .varint(value)))
			case 1:
				guard pos + 8 <= bytes.count else { return nil }
				fields.append(ProtobufField(number: number, value: .fixed64(Array(bytes[pos..<pos + 8])))); pos += 8
			case 2:
				guard let length = readVarint(), length <= UInt64(bytes.count - pos) else { return nil }
				let end = pos + Int(length)
				fields.append(ProtobufField(number: number, value: .lengthDelimited(Array(bytes[pos..<end])))); pos = end
			case 5:
				guard pos + 4 <= bytes.count else { return nil }
				fields.append(ProtobufField(number: number, value: .fixed32(Array(bytes[pos..<pos + 4])))); pos += 4
			default:
				return nil
			}
		}
		return fields
	}

	// MARK: Component files & metadata for relocated tables

	/// Derives the `Index/Tables/*` file path for a relocated table object: the
	/// component's type stem plus its new id (e.g. `Tables/DataList-1737286-2.iwa`).
	private static func relocatedTablePath(_ originalPath: String, newID: UInt64) -> String {
		let name = (originalPath as NSString).lastPathComponent          // e.g. DataList-1733192-2.iwa
		let stem = name.prefix { $0 != "-" && $0 != "." }                // e.g. DataList
		return "Index/Tables/\(stem)-\(newID)-2.iwa"
	}

	/// Rebuilds a `PackageMetadata` (type 11006) payload so it covers every table:
	/// the high-water mark is raised, each base component's table-involving external
	/// references (`#6`/`#7`) are cloned per id offset, and every `Index/Tables/*`
	/// `ComponentInfo` is cloned (id, locator, references shifted) for each table
	/// beyond the first. Other fields are preserved verbatim.
	static func relocateComponentMetadata(_ payload: [UInt8], tableCount: Int, highWaterMark: UInt64) -> [UInt8] {
		let offsets = (1..<max(tableCount, 1)).map { UInt64($0) * idOffsetStep }
		var writer = ProtobufWriter()
		for field in ProtobufMessage(payload).fields {
			switch field.number {
			case 1:
				writer.varintField(1, highWaterMark)
			case 3:
				guard case .lengthDelimited(let componentInfo) = field.value else { writer.append(field); continue }
				let message = ProtobufMessage(componentInfo)
				let name = message.bytes(2).map { String(decoding: $0, as: UTF8.self) } ?? ""
				if name.hasPrefix("Tables/") {
					// A per-table component file: keep the original, add an offset clone per table.
					writer.bytesField(3, componentInfo)
					for offset in offsets { writer.bytesField(3, cloneTablesComponentInfo(message, offset: offset)) }
				} else {
					// A shared component: keep its fields and append the offset clones of
					// every table-involving external reference for each extra table.
					writer.bytesField(3, appendingCrossReferenceClones(message, offsets: offsets))
				}
			default:
				writer.append(field)
			}
		}
		return writer.bytes
	}

	/// Clones a `Tables/*` `ComponentInfo` at an id offset: the primary id (`#1`) and
	/// locator (`#3`) embed the shifted id; external references (`#6`/`#7`) are shifted.
	private static func cloneTablesComponentInfo(_ info: ProtobufMessage, offset: UInt64) -> [UInt8] {
		let id = info.varint(1) ?? 0
		let stem = (info.bytes(2).map { String(decoding: $0, as: UTF8.self) } ?? "Tables/").split(separator: "/").last.map(String.init) ?? ""
		var writer = ProtobufWriter()
		for field in info.fields {
			switch field.number {
			case 1: writer.varintField(1, id + offset)
			case 3: writer.stringField(3, "Tables/\(stem)-\(id + offset)-2")
			case 6, 7: writer.bytesField(field.number, shiftCrossReference(field, offset: offset))
			default: writer.append(field)
			}
		}
		// A non-suffixed component (`#3` absent in the original) still needs a locator,
		// because the cloned file is always id-suffixed.
		if info.bytes(3) == nil { writer.stringField(3, "Tables/\(stem)-\(id + offset)-2") }
		return writer.bytes
	}

	/// Re-emits a `ComponentInfo`'s fields, then appends an offset clone of each
	/// table-involving external reference (`#6`/`#7`) for every extra-table offset.
	private static func appendingCrossReferenceClones(_ info: ProtobufMessage, offsets: [UInt64]) -> [UInt8] {
		var writer = ProtobufWriter()
		for field in info.fields { writer.append(field) }
		for offset in offsets {
			for field in info.fields where (field.number == 6 || field.number == 7) {
				guard case .lengthDelimited(let ref) = field.value else { continue }
				let reference = ProtobufMessage(ref)
				let component = reference.varint(1) ?? 0
				let object = reference.varint(2) ?? 0
				// Only references that reach a relocated table object need a clone.
				if capturedIDs.contains(component) || capturedIDs.contains(object) {
					writer.bytesField(field.number, shiftCrossReference(field, offset: offset))
				}
			}
		}
		return writer.bytes
	}

	/// Shifts an external reference's component id (`#1`) and object id (`#2`).
	private static func shiftCrossReference(_ field: ProtobufField, offset: UInt64) -> [UInt8] {
		guard case .lengthDelimited(let ref) = field.value else { return [] }
		var writer = ProtobufWriter()
		for refField in ProtobufMessage(ref).fields {
			if case .varint(let value) = refField.value, (refField.number == 1 || refField.number == 2) {
				writer.varintField(refField.number, shifted(value, by: offset))
			} else {
				writer.append(refField)
			}
		}
		return writer.bytes
	}
}

private extension Array where Element == UInt8 {
	/// The payload portion of a verbatim object record (skips length-prefixed
	/// ArchiveInfo; assumes a single MessageInfo, as all table objects have).
	var payloadOnly: [UInt8] {
		var pos = 0
		func readVarint() -> UInt64 {
			var shift = UInt64(0), result = UInt64(0)
			while pos < count { let b = self[pos]; pos += 1; result |= UInt64(b & 0x7F) << shift; if b & 0x80 == 0 { break }; shift += 7 }
			return result
		}
		let aiLength = Int(readVarint())
		pos += aiLength
		return Array(self[pos...])
	}
}
