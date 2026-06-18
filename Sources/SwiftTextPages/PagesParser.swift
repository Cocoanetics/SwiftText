import Foundation

/// Reads a `.pages` archive and reconstructs its body text and paragraph
/// structure from the iWork Archive (`.iwa`) object graph.
final class PagesParser {
	/// Well-known iWork archive type and field numbers (from the
	/// reverse-engineered iWork schemas). These have been stable across recent
	/// Pages versions; anything that fails to resolve degrades to plain text.
	private enum IWork {
		/// `TSWP.StorageArchive` — a run of text (body, header, footnote, cell…).
		static let storageArchiveType: UInt64 = 2001
		/// `StorageArchive.kind` — 0 is the document body.
		static let storageKindField = 1
		static let bodyKind: UInt64 = 0
		static let headerKind: UInt64 = 1
		static let footnoteKind: UInt64 = 2
		/// `StorageArchive.text` — repeated string chunks; concatenate for the
		/// full text of the storage.
		static let textField = 3
		/// `StorageArchive.table_para_style` — paragraph-style run table.
		static let paraStyleTableField = 5
		/// `StorageArchive.table_para_data` — per-paragraph data (carries the list
		/// indent level in field 3 of each entry).
		static let paraDataTableField = 6
		/// `StorageArchive.table_list_style` — list-style run table.
		static let listStyleTableField = 7
		/// `StorageArchive.table_char_style` — character-style run table.
		static let charStyleTableField = 8
		/// Within a run table, repeated entries.
		static let runEntryField = 1
		/// Within a run entry: the character index and the style reference.
		static let runCharIndexField = 1
		static let runStyleRefField = 2
		/// Within a para-data entry: the list nesting depth. Pages stores it in field 2
		/// ("first") — it's what drives the per-level indent lookup in the list style.
		static let listLevelField = 2
		/// `TSP.Reference.identifier`.
		static let referenceIdentifierField = 1
		/// Char/paragraph `…StyleArchive.char_properties`.
		static let charPropertiesField = 11
		/// Within a paragraph/character style: the `super` TSS.StyleArchive (field 1),
		/// which carries `name` (field 1) and the stable `style_identifier` (field 2).
		static let styleSuperField = 1
		static let styleIdentifierField = 2
		/// Within char properties: bold, italic, strikethrough, and font size.
		static let boldField = 1
		static let italicField = 2
		static let strikethroughField = 12
		static let fontSizeField = 3
		static let fontNameField = 5
		/// Smart-field run table (`#11`): maps character ranges to hyperlink (2032)
		/// objects, whose field 2 is the destination URL.
		static let smartFieldTableField = 11
		static let hyperlinkURLField = 2
		/// `ListStyleArchive` — base style (field 1), whose parent reference
		/// (field 3) supports inheritance, and the per-level marker type (field 11:
		/// 0 = none, 2 = bullet, 3 = numbered).
		static let listStyleBaseField = 1
		static let listStyleParentField = 3
		static let listMarkerTypeField = 11
		static let listBulletMarker: UInt64 = 2
		static let listOrderedMarker: UInt64 = 3

		// Native tables (`TST`). An attachment run-table entry can resolve to a
		// drawable attachment whose chain reaches the table model and its cell store.
		/// Drawable attachment (`#1` → `TableInfoArchive`).
		static let drawableAttachmentType: UInt64 = 2003
		/// `TableInfoArchive` (`#2` → `TableModelArchive`).
		static let tableInfoType: UInt64 = 6000
		static let tableInfoModelField = 2
		/// `TableModelArchive`: `#6` rows, `#7` columns, `#4` base_data_store.
		static let tableModelType: UInt64 = 6001
		static let tableRowCountField = 6
		static let tableColumnCountField = 7
		static let tableDataStoreField = 4
		/// `DataStore`: `#3` tiles (`TileStorage`), `#4` stringTable (cell `DataList`).
		static let dataStoreTilesField = 3
		static let dataStoreStringTableField = 4
		/// `TileStorage.Tile.tile` (`#1` → `{ #2 → tile }`); `Tile.rowInfos` = `#5`,
		/// each `TileRowInfo` with `#6` cell buffer and `#7` cell offsets.
		static let tileStorageTileField = 1
		static let tileStorageTileRefField = 2
		static let tileRowInfosField = 5
		static let tileCellBufferField = 6
		static let tileCellOffsetsField = 7
		/// `DataList` shared-string entries: repeated `#3 { #1 key, #3 string }`.
		static let dataListEntryField = 3
		static let dataListKeyField = 1
		static let dataListStringField = 3
		/// A string cell stores its `DataList` key as a little-endian `u32` at byte 12.
		static let cellKeyByteOffset = 12
		/// `DataStore.styleTable` (cell paragraph styles), entry `#4 { #1 styleRef }`.
		static let dataStoreStyleTableField = 5
		static let styleTableRefField = 4
		/// A cell's flags byte (offset 8); bit `0x40` set means a styleTable key (W1)
		/// follows the string key at byte 16.
		static let cellFlagsByteOffset = 8
		static let cellStyleKeyBit: UInt8 = 0x40
		static let cellStyleKeyByteOffset = 16
		/// `DataStore.rich_text_table` (#17): a `DataList` whose entries (`#9 { #1 ref }`)
		/// reach a cell's rich text (via a 6218 wrapper → 2001 `StorageArchive`).
		static let dataStoreRichTextTableField = 17
		static let dataListWrapperRefField = 9
		/// A cell's type byte (offset 1): `0x02` number, `0x03` string, `0x05` date,
		/// `0x06` duration, `0x07` bool, `0x09` rich. For numeric kinds the *frozen*
		/// value (the cached formula result, no recalculation) lives at byte 12: a
		/// decimal128 (number), a `double` of seconds-since-2001 (date), or a `double`
		/// (duration / bool). String/rich cells carry a `u32@12` key instead.
		static let cellTypeByteOffset = 1
		static let cellNumberType: UInt8 = 0x02
		static let cellDateType: UInt8 = 0x05
		static let cellDurationType: UInt8 = 0x06
		static let cellBoolType: UInt8 = 0x07
		static let cellRichType: UInt8 = 0x09
		/// `ParagraphStylePropertiesArchive.alignment` (#1): 1 = right, 2 = center.
		static let paragraphPropertiesField = 12
		static let paragraphAlignmentField = 1
	}

	/// The kind of list marker a paragraph's list style defines at a given level.
	private enum ListMarker {
		case none
		case bullet
		case ordered
	}

	func readDocument(from url: URL) throws -> PagesDocument {
		guard FileManager.default.fileExists(atPath: url.path) else {
			throw PagesFileError.fileNotFound(url)
		}

		// Modern (iWork '13+) documents store content as Index/*.iwa objects.
		let indexEntries = try PagesContainer.entries(at: url, prefix: "Index/", suffix: ".iwa")
		if !indexEntries.isEmpty {
			return buildDocument(from: loadObjectStore(from: indexEntries))
		}

		// Legacy (iWork '09) documents store a single uncompressed index.xml.
		if let indexXML = PagesContainer.data(at: url, named: "index.xml") {
			return try PagesLegacyParser().parseDocument(from: indexXML)
		}
		// The very oldest documents gzip that index; flag it rather than mis-report.
		if PagesContainer.data(at: url, named: "index.xml.gz") != nil {
			throw PagesFileError.legacyGzipUnsupported(url)
		}

		throw PagesFileError.notAnIWorkDocument(url)
	}

	/// Decodes the given `Index/*.iwa` entries into a unified object store.
	private func loadObjectStore(from entries: [PagesContainer.Entry]) -> IWAObjectStore {
		var store = IWAObjectStore()
		for entry in entries {
			// Skip any entry that isn't a standard Snappy/Protobuf IWA file. Some
			// auxiliary index files (e.g. `OperationStorage`, a collaboration/undo
			// log that begins with a `bvxn` magic) use other framing and carry no
			// document text — they must not block extracting `Document.iwa`.
			guard let objects = try? IWAArchive.objects(from: entry.data) else { continue }
			for object in objects {
				store.add(object)
			}
		}
		return store
	}

	/// Selects the body storages and turns their text into structured paragraphs.
	private func buildDocument(from store: IWAObjectStore) -> PagesDocument {
		let storages = store.objects(ofType: IWork.storageArchiveType)

		// Prefer the document body. If a document keeps all its text in boxes or
		// other containers (so there is no body storage), fall back to the single
		// largest non-header storage so we still produce output.
		var bodyStorages = storages.filter { storageKind($0) == IWork.bodyKind }
		if bodyStorages.allSatisfy({ storageText($0).isEmpty }) {
			let fallback = storages
				.filter { storageKind($0) != IWork.headerKind }
				.max { storageText($0).count < storageText($1).count }
			bodyStorages = fallback.map { [$0] } ?? []
		}

		let catalog = PagesImageCatalog(store: store)

		// Footnote content lives in kind == 2 storages, keyed by their identifier;
		// the body's footnote run table references them.
		var footnoteTexts = [UInt64: String]()
		for storage in storages where storageKind(storage) == IWork.footnoteKind {
			footnoteTexts[storage.identifier] = footnoteText(storage)
		}
		let footnoteStorageIDs = Set(footnoteTexts.keys)

		var paragraphs = [PagesDocument.Paragraph]()
		var footnotes = [PagesDocument.Footnote]()
		var footnoteCounter = 0
		for storage in bodyStorages {
			let text = storageText(storage)
			guard !text.isEmpty else { continue }
			paragraphs.append(contentsOf: makeParagraphs(
				in: text, storage: storage, store: store, catalog: catalog,
				footnoteStorageIDs: footnoteStorageIDs, footnoteTexts: footnoteTexts,
				footnoteCounter: &footnoteCounter, footnotes: &footnotes
			))
		}

		let imageAssets = catalog.assets.map {
			PagesDocument.ImageAsset(referenceName: $0.referenceName, dataFileName: $0.dataFileName)
		}
		return PagesDocument(paragraphs: paragraphs, imageAssets: imageAssets, footnotes: footnotes)
	}

	private func storageKind(_ object: IWAObject) -> UInt64 {
		ProtobufMessage(object.payload).varint(IWork.storageKindField) ?? IWork.bodyKind
	}

	/// Concatenates a storage's repeated text chunks into its full text.
	private func storageText(_ object: IWAObject) -> String {
		let message = ProtobufMessage(object.payload)
		var text = ""
		for chunk in message.allBytes(IWork.textField) {
			text += String(decoding: chunk, as: UTF8.self)
		}
		return text
	}

	/// Splits a storage's text into paragraphs, resolving each paragraph's font
	/// size, inline bold/italic spans, list membership, and the image (if any)
	/// behind each inline-attachment anchor.
	private func makeParagraphs(
		in text: String, storage: IWAObject, store: IWAObjectStore, catalog: PagesImageCatalog,
		footnoteStorageIDs: Set<UInt64>, footnoteTexts: [UInt64: String],
		footnoteCounter: inout Int, footnotes: inout [PagesDocument.Footnote]
	) -> [PagesDocument.Paragraph] {
		let runs = paragraphStyleRuns(storage)
		let charRuns = characterRuns(storage, store: store)
		let levels = listLevels(storage)
		let listStyles = listStyleRuns(storage)
		let anchorNames = attachmentImageNames(in: storage, text: text, catalog: catalog)
		let anchorTables = attachmentTableGrids(in: storage, text: text, store: store)
		let footnoteRefs = footnoteStorageIDs.isEmpty
			? []
			: footnoteRuns(storage, footnoteStorageIDs: footnoteStorageIDs, store: store)
		var result = [PagesDocument.Paragraph]()
		// Paragraph separators are \n / U+2029; soft breaks (U+2028) stay inside a
		// paragraph. Run-table character indices are UTF-16 offsets (Cocoa text),
		// so offsets are tracked in UTF-16 units.
		var current = String.UnicodeScalarView()
		var currentAttachments = [String?]()
		var currentTables = [PagesDocument.Paragraph.Table]()
		var currentEmphasis = [PagesDocument.Paragraph.EmphasisSpan]()
		var currentFootnotes = [PagesDocument.Paragraph.FootnoteMarker]()
		var footnoteIndex = 0
		var paragraphStartUTF16 = 0
		var utf16Offset = 0

		// Character emphasis carries forward across paragraphs; advance through the
		// global run table as the offset grows.
		var charRunIndex = 0
		var activeBold = false
		var activeItalic = false
		var activeStrike = false
		var activeCode = false
		let linkSpans = self.linkRuns(storage, store: store)

		func flush() {
			let paragraphText = String(current)
			let style = resolvedStyle(atUTF16: paragraphStartUTF16, runs: runs, store: store)
			let (listLevel, listOrdered) = listMembership(atUTF16: paragraphStartUTF16, levels: levels, listStyles: listStyles, store: store)
			// Clip the global hyperlink spans to this paragraph and rebase to paragraph-
			// relative UTF-16 offsets.
			let paragraphEnd = paragraphStartUTF16 + paragraphText.utf16.count
			let paragraphLinks = linkSpans.compactMap { span -> PagesDocument.Paragraph.LinkRun? in
				let lo = max(span.start, paragraphStartUTF16), hi = min(span.end, paragraphEnd)
				guard lo < hi else { return nil }
				return .init(start: lo - paragraphStartUTF16, end: hi - paragraphStartUTF16, url: span.url)
			}
			result.append(PagesDocument.Paragraph(
				text: paragraphText,
				fontSize: style.fontSize,
				bold: style.bold,
				headingLevel: style.headingLevel,
				attachmentReferences: currentAttachments,
				emphasis: currentEmphasis,
				links: paragraphLinks,
				listLevel: listLevel,
				listOrdered: listOrdered,
				footnoteMarkers: currentFootnotes,
				tables: currentTables,
				isCodeBlock: style.isCodeBlock
			))
			current = String.UnicodeScalarView()
			currentAttachments = []
			currentTables = []
			currentEmphasis = []
			currentFootnotes = []
		}

		for scalar in text.unicodeScalars {
			while charRunIndex < charRuns.count, charRuns[charRunIndex].index <= utf16Offset {
				activeBold = charRuns[charRunIndex].bold
				activeItalic = charRuns[charRunIndex].italic
				activeStrike = charRuns[charRunIndex].strike
				activeCode = charRuns[charRunIndex].code
				charRunIndex += 1
			}
			// Footnote reference marks sit at a character index (no text character);
			// number them in reading order and record their definitions.
			while footnoteIndex < footnoteRefs.count, footnoteRefs[footnoteIndex].index <= utf16Offset {
				footnoteCounter += 1
				currentFootnotes.append(.init(offset: footnoteRefs[footnoteIndex].index - paragraphStartUTF16, number: footnoteCounter))
				let storageID = footnoteRefs[footnoteIndex].storageID
				footnotes.append(.init(number: footnoteCounter, text: footnoteTexts[storageID] ?? ""))
				footnoteIndex += 1
			}
			let width = scalar.value > 0xFFFF ? 2 : 1
			if scalar == "\n" || scalar == "\u{2029}" {
				flush()
				utf16Offset += width
				paragraphStartUTF16 = utf16Offset
			} else {
				if scalar == "\u{FFFC}" {
					currentAttachments.append(anchorNames[utf16Offset])
					if let grid = anchorTables[utf16Offset] { currentTables.append(grid) }
				}
				if currentEmphasis.isEmpty || currentEmphasis.last?.bold != activeBold
					|| currentEmphasis.last?.italic != activeItalic || currentEmphasis.last?.strike != activeStrike
					|| currentEmphasis.last?.code != activeCode {
					currentEmphasis.append(.init(start: utf16Offset - paragraphStartUTF16, bold: activeBold, italic: activeItalic, strike: activeStrike, code: activeCode))
				}
				current.append(scalar)
				utf16Offset += width
			}
		}
		// Any footnote marks at the very end of the text.
		while footnoteIndex < footnoteRefs.count {
			footnoteCounter += 1
			currentFootnotes.append(.init(offset: utf16Offset - paragraphStartUTF16, number: footnoteCounter))
			footnotes.append(.init(number: footnoteCounter, text: footnoteTexts[footnoteRefs[footnoteIndex].storageID] ?? ""))
			footnoteIndex += 1
		}
		flush()
		return result
	}

	/// Maps each inline-attachment anchor (`U+FFFC`, by UTF-16 offset) to the
	/// reference name of the content image it shows, when it shows one. Anchors
	/// for text boxes, smart fields, etc. resolve to nothing.
	private func attachmentImageNames(in storage: IWAObject, text: String, catalog: PagesImageCatalog) -> [Int: String] {
		var anchorOffsets = Set<Int>()
		var offset = 0
		for scalar in text.unicodeScalars {
			if scalar == "\u{FFFC}" { anchorOffsets.insert(offset) }
			offset += scalar.value > 0xFFFF ? 2 : 1
		}
		guard !anchorOffsets.isEmpty else { return [:] }

		// The attachment run table has the same (index, reference) entry shape as
		// the other run tables; rather than hard-code its field number, scan every
		// run-table-shaped field and keep entries at an anchor offset whose
		// reference resolves to a content image.
		var names = [Int: String]()
		let message = ProtobufMessage(storage.payload)
		for field in message.fields {
			guard case .lengthDelimited(let bytes) = field.value else { continue }
			for entry in ProtobufMessage(bytes).messages(IWork.runEntryField) {
				guard let rawIndex = entry.varint(IWork.runCharIndexField) else { continue }
				let index = Int(rawIndex)
				guard anchorOffsets.contains(index), names[index] == nil else { continue }
				guard let reference = entry.message(IWork.runStyleRefField),
				      let objectID = reference.varint(IWork.referenceIdentifierField) else { continue }
				if let name = catalog.imageReferenceName(forAttachment: objectID) {
					names[index] = name
				}
			}
		}
		return names
	}

	/// Maps each inline-attachment anchor (`U+FFFC`, by UTF-16 offset) to the native
	/// table grid it shows, when it anchors one. Anchors for images, text boxes, etc.
	/// resolve to nothing. Scans every run-table-shaped field for anchor references
	/// that resolve to a drawable attachment whose chain reaches a table model.
	private func attachmentTableGrids(in storage: IWAObject, text: String, store: IWAObjectStore) -> [Int: PagesDocument.Paragraph.Table] {
		var anchorOffsets = Set<Int>()
		var offset = 0
		for scalar in text.unicodeScalars {
			if scalar == "\u{FFFC}" { anchorOffsets.insert(offset) }
			offset += scalar.value > 0xFFFF ? 2 : 1
		}
		guard !anchorOffsets.isEmpty else { return [:] }

		var grids = [Int: PagesDocument.Paragraph.Table]()
		for field in ProtobufMessage(storage.payload).fields {
			guard case .lengthDelimited(let bytes) = field.value else { continue }
			for entry in ProtobufMessage(bytes).messages(IWork.runEntryField) {
				guard let rawIndex = entry.varint(IWork.runCharIndexField) else { continue }
				let index = Int(rawIndex)
				guard anchorOffsets.contains(index), grids[index] == nil,
				      let reference = entry.message(IWork.runStyleRefField),
				      let objectID = reference.varint(IWork.referenceIdentifierField),
				      let grid = tableGrid(forAttachment: objectID, store: store) else { continue }
				grids[index] = grid
			}
		}
		return grids
	}

	/// Follows a drawable attachment (`type 2003`) through its `TableInfoArchive`
	/// (`6000`) to the `TableModelArchive` (`6001`) and reconstructs the cell grid
	/// from the tile (cell → `DataList` key) and the cell-string list, plus each
	/// column's alignment (from the styled cells' paragraph styles). Returns `nil`
	/// when the object isn't a table attachment.
	private func tableGrid(forAttachment attachmentID: UInt64, store: IWAObjectStore) -> PagesDocument.Paragraph.Table? {
		guard let attachment = store.object(attachmentID), attachment.type == IWork.drawableAttachmentType,
		      let infoID = ProtobufMessage(attachment.payload).message(IWork.referenceIdentifierField)?.varint(IWork.referenceIdentifierField),
		      let info = store.object(infoID), info.type == IWork.tableInfoType,
		      let modelID = ProtobufMessage(info.payload).message(IWork.tableInfoModelField)?.varint(IWork.referenceIdentifierField),
		      let model = store.object(modelID), model.type == IWork.tableModelType else { return nil }

		let modelMessage = ProtobufMessage(model.payload)
		let rows = Int(modelMessage.varint(IWork.tableRowCountField) ?? 0)
		let columns = Int(modelMessage.varint(IWork.tableColumnCountField) ?? 0)
		guard rows > 0, columns > 0, let dataStore = modelMessage.message(IWork.tableDataStoreField) else { return nil }

		// stringTable → cell-string DataList → key → string.
		var stringsByKey = [UInt64: String]()
		if let stringTableID = dataStore.message(IWork.dataStoreStringTableField)?.varint(IWork.referenceIdentifierField),
		   let dataList = store.object(stringTableID) {
			for entry in ProtobufMessage(dataList.payload).messages(IWork.dataListEntryField) {
				if let key = entry.varint(IWork.dataListKeyField), let string = entry.bytes(IWork.dataListStringField) {
					stringsByKey[key] = String(decoding: string, as: UTF8.self)
				}
			}
		}

		// styleTable → key → cell paragraph style id (for alignment).
		var styleIDByKey = [UInt64: UInt64]()
		if let styleTableID = dataStore.message(IWork.dataStoreStyleTableField)?.varint(IWork.referenceIdentifierField),
		   let styleList = store.object(styleTableID) {
			for entry in ProtobufMessage(styleList.payload).messages(IWork.dataListEntryField) {
				if let key = entry.varint(IWork.dataListKeyField),
				   let styleID = entry.message(IWork.styleTableRefField)?.varint(IWork.referenceIdentifierField) {
					styleIDByKey[key] = styleID
				}
			}
		}
		func alignment(forStyleKey key: UInt64) -> PagesDocument.Paragraph.Table.ColumnAlignment {
			guard let styleID = styleIDByKey[key], let style = store.object(styleID),
			      let value = ProtobufMessage(style.payload).message(IWork.paragraphPropertiesField)?.varint(IWork.paragraphAlignmentField) else { return .left }
			switch value {
			case 1: return .right
			case 2: return .center
			default: return .left
			}
		}

		// rich_text_table → key → cell text StorageArchive id (for in-cell bold/italic).
		// Each entry's reference is a 6218 wrapper around the 2001 storage; a direct
		// storage reference is also tolerated for resilience against other writers.
		var richStorageByKey = [UInt64: UInt64]()
		if let richTableID = dataStore.message(IWork.dataStoreRichTextTableField)?.varint(IWork.referenceIdentifierField),
		   let richList = store.object(richTableID) {
			for entry in ProtobufMessage(richList.payload).messages(IWork.dataListEntryField) {
				guard let key = entry.varint(IWork.dataListKeyField),
				      let refID = entry.message(IWork.dataListWrapperRefField)?.varint(IWork.referenceIdentifierField),
				      let ref = store.object(refID) else { continue }
				let storageID = ref.type == IWork.storageArchiveType
					? refID
					: ProtobufMessage(ref.payload).message(IWork.referenceIdentifierField)?.varint(IWork.referenceIdentifierField)
				if let storageID { richStorageByKey[key] = storageID }
			}
		}

		// tiles → the single tile holding all rows → per-row cell keys.
		guard let tileID = dataStore.message(IWork.dataStoreTilesField)?
				.message(IWork.tileStorageTileField)?
				.message(IWork.tileStorageTileRefField)?
				.varint(IWork.referenceIdentifierField),
		      let tile = store.object(tileID) else { return nil }

		var grid = Array(repeating: Array(repeating: "", count: columns), count: rows)
		var columnAlignments = Array(repeating: PagesDocument.Paragraph.Table.ColumnAlignment.left, count: columns)
		// Per-column body-cell census, for the implicit alignment Pages applies by value
		// type: a column whose body cells are all numeric/date (no text) right-aligns by
		// default — matching the display — unless an explicit alignment override is set.
		var columnHasNumber = Array(repeating: false, count: columns)
		var columnHasText = Array(repeating: false, count: columns)
		var columnExplicitlyAligned = Array(repeating: false, count: columns)
		for rowInfo in ProtobufMessage(tile.payload).messages(IWork.tileRowInfosField) {
			guard let rowIndex = rowInfo.varint(IWork.runCharIndexField).map(Int.init), rowIndex < rows,
			      let buffer = rowInfo.bytes(IWork.tileCellBufferField),
			      let offsets = rowInfo.bytes(IWork.tileCellOffsetsField) else { continue }
			let cellStarts = cellOffsets(offsets)
			for (column, start) in cellStarts.enumerated() where column < columns {
				guard start + IWork.cellKeyByteOffset + 4 <= buffer.count else { continue }
				let base = start + IWork.cellKeyByteOffset
				let key = UInt64(buffer[base]) | UInt64(buffer[base + 1]) << 8 | UInt64(buffer[base + 2]) << 16 | UInt64(buffer[base + 3]) << 24
				let typeByte = start + IWork.cellTypeByteOffset < buffer.count ? buffer[start + IWork.cellTypeByteOffset] : 0
				if typeByte == IWork.cellRichType, let storageID = richStorageByKey[key], let storage = store.object(storageID) {
					// A rich cell's text + char-style runs reconstruct the inline markup;
					// its column alignment comes from the storage's own paragraph style.
					grid[rowIndex][column] = cellMarkdown(storage, store: store)
					if rowIndex >= 1, let aligned = cellAlignment(storage, store: store) {
						columnAlignments[column] = aligned
					}
				} else if let frozen = frozenValue(buffer, at: start, type: typeByte) {
					// Numeric / date / bool / duration cells store their cached value — the
					// formula result, no recalculation — so the table reads as static text.
					grid[rowIndex][column] = frozen
				} else if let string = stringsByKey[key] {
					grid[rowIndex][column] = string
				}
				// Census body cells by value type for the implicit-alignment default.
				if rowIndex >= 1 {
					switch typeByte {
					case IWork.cellNumberType, IWork.cellDateType, IWork.cellDurationType, IWork.cellBoolType:
						columnHasNumber[column] = true
					default:
						if !grid[rowIndex][column].isEmpty { columnHasText[column] = true }
					}
				}
				// Column alignment comes from body cells: a styled cell (flag bit set)
				// carries a styleTable key in W1; an unstyled cell is left-aligned.
				if rowIndex >= 1, start + IWork.cellFlagsByteOffset < buffer.count,
				   buffer[start + IWork.cellFlagsByteOffset] & IWork.cellStyleKeyBit != 0,
				   start + IWork.cellStyleKeyByteOffset + 4 <= buffer.count {
					let styleBase = start + IWork.cellStyleKeyByteOffset
					let styleKey = UInt64(buffer[styleBase]) | UInt64(buffer[styleBase + 1]) << 8 | UInt64(buffer[styleBase + 2]) << 16 | UInt64(buffer[styleBase + 3]) << 24
					columnAlignments[column] = alignment(forStyleKey: styleKey)
					columnExplicitlyAligned[column] = true
				}
			}
		}
		// Implicit default: a column of purely numeric/date values right-aligns (as Pages
		// displays it) unless an explicit alignment override is present.
		for column in 0..<columns where !columnExplicitlyAligned[column] && columnHasNumber[column] && !columnHasText[column] {
			columnAlignments[column] = .right
		}
		return PagesDocument.Paragraph.Table(cells: grid, columnAlignments: columnAlignments)
	}

	/// Reconstructs a rich cell's Markdown: the cell-storage text with each
	/// character-emphasis run wrapped in `**`/`*`/`~~` — reusing the body's emphasis
	/// machinery so inline bold/italic/strikethrough round-trip out of a table cell.
	private func cellMarkdown(_ storage: IWAObject, store: IWAObjectStore) -> String {
		let text = storageText(storage)
		let spans = characterRuns(storage, store: store).map {
			PagesDocument.Paragraph.EmphasisSpan(start: $0.index, bold: $0.bold, italic: $0.italic, strike: $0.strike)
		}
		let paragraph = PagesDocument.Paragraph(text: text, emphasis: spans)
		return paragraph.renderedText(inliningImages: false, applyingEmphasis: true)
	}

	/// A rich cell carries its column's alignment in its storage's own paragraph style
	/// (`#5` run table → style → `#12 #1`), since the `05 09` record has no styleTable
	/// key. Returns `nil` when the style sets no explicit alignment (i.e. left).
	private func cellAlignment(_ storage: IWAObject, store: IWAObjectStore) -> PagesDocument.Paragraph.Table.ColumnAlignment? {
		guard let styleID = paragraphStyleRuns(storage).first(where: { $0.styleID != nil })?.styleID,
		      let style = store.object(styleID),
		      let value = ProtobufMessage(style.payload).message(IWork.paragraphPropertiesField)?.varint(IWork.paragraphAlignmentField) else { return nil }
		switch value {
		case 1: return .right
		case 2: return .center
		default: return nil
		}
	}

	/// The frozen (cached) value of a numeric / date / bool / duration cell rendered as
	/// static text — the displayed formula result, no recalculation. Returns `nil` for
	/// text cells (which carry a string-table key the caller resolves instead).
	private func frozenValue(_ b: [UInt8], at start: Int, type: UInt8) -> String? {
		let o = start + IWork.cellKeyByteOffset
		func readDouble(_ off: Int) -> Double? {
			guard off + 8 <= b.count else { return nil }
			var bits: UInt64 = 0; for k in 0..<8 { bits |= UInt64(b[off + k]) << (8 * k) }
			return Double(bitPattern: bits)
		}
		switch type {
		case IWork.cellNumberType:
			return Self.decimal128String(b, at: o)
		case IWork.cellDateType:
			guard let seconds = readDouble(o) else { return nil }
			let formatter = DateFormatter()
			formatter.dateFormat = "yyyy-MM-dd HH:mm"
			formatter.timeZone = TimeZone(identifier: "UTC")
			return formatter.string(from: Date(timeIntervalSinceReferenceDate: seconds))
		case IWork.cellBoolType:
			guard let v = readDouble(o) else { return nil }
			return v != 0 ? "true" : "false"
		case IWork.cellDurationType:
			guard let s = readDouble(o) else { return nil }
			return "\(Int(s.rounded()))s"
		default:
			return nil
		}
	}

	/// Decodes an IEEE 754-2008 decimal128 (BID) at `o` (16 bytes, little-endian) to an
	/// exact decimal string: value = coefficient × 10^(exponent). Handles the common
	/// small-coefficient form (≤ 64-bit coefficient); returns `nil` for the rarer large
	/// form so the caller falls back gracefully.
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

	/// Parses a tile row's `u16` cell-offset array (little-endian), terminated by the
	/// `0xFFFF` sentinel — the byte offset of each cell into the cell buffer.
	private func cellOffsets(_ bytes: [UInt8]) -> [Int] {
		var offsets = [Int]()
		var i = 0
		while i + 1 < bytes.count {
			let value = Int(bytes[i]) | Int(bytes[i + 1]) << 8
			if value == 0xFFFF { break }
			offsets.append(value)
			i += 2
		}
		return offsets
	}

	/// Reads the paragraph-style run table: a sorted list of
	/// `(character index, style identifier?)`. Entries without a style reference
	/// indicate a paragraph break that keeps the previous style.
	private func paragraphStyleRuns(_ storage: IWAObject) -> [(index: Int, styleID: UInt64?)] {
		let message = ProtobufMessage(storage.payload)
		guard let table = message.message(IWork.paraStyleTableField) else { return [] }
		var runs = [(index: Int, styleID: UInt64?)]()
		for entry in table.messages(IWork.runEntryField) {
			guard let index = entry.varint(IWork.runCharIndexField) else { continue }
			var styleID: UInt64?
			if let reference = entry.message(IWork.runStyleRefField) {
				styleID = reference.varint(IWork.referenceIdentifierField)
			}
			runs.append((index: Int(index), styleID: styleID))
		}
		runs.sort { $0.index < $1.index }
		return runs
	}

	/// Finds the style active at a character index, then resolves its font size,
	/// bold flag, and — for a faithful Markdown round-trip — an explicit heading
	/// level read from the paragraph style's stable `style_identifier`.
	private func resolvedStyle(atUTF16 index: Int, runs: [(index: Int, styleID: UInt64?)], store: IWAObjectStore) -> (fontSize: Double?, bold: Bool, headingLevel: Int?, isCodeBlock: Bool) {
		var activeStyleID: UInt64?
		for run in runs {
			guard run.index <= index else { break }
			if let styleID = run.styleID { activeStyleID = styleID }
		}
		guard let activeStyleID, let styleObject = store.object(activeStyleID) else {
			return (nil, false, nil, false)
		}
		let style = ProtobufMessage(styleObject.payload)
		// The paragraph style's `super` (TSS.StyleArchive, field 1) carries the stable,
		// non-localized `style_identifier` (field 2), e.g. "…-paragraphstyle-Heading 2"
		// or our own "swifttext-code-block" for the preformatted style.
		let identifier = style.message(IWork.styleSuperField)
			.flatMap { $0.bytes(IWork.styleIdentifierField) }
			.map { String(decoding: $0, as: UTF8.self) }
		let level = identifier.flatMap(Self.headingLevel(forStyleIdentifier:))
		let isCodeBlock = identifier == PagesStyleIdentifier.codeBlock
		guard let charProperties = style.message(IWork.charPropertiesField) else {
			return (nil, false, level, isCodeBlock)
		}
		let bold = (charProperties.varint(IWork.boldField) ?? 0) != 0
		let fontSize = charProperties.float(IWork.fontSizeField).map(Double.init)
		return (fontSize, bold, level, isCodeBlock)
	}

	/// Maps a paragraph style's `style_identifier` to a Markdown heading level so
	/// headings round-trip exactly (`#`↔Heading 1, `##`↔Heading 2, …). The identifier
	/// is stable across localizations (e.g. "text-11-paragraphstyle-Heading 1"); a
	/// document Title maps to level 1. Returns nil for body/other styles, leaving the
	/// font-size heuristic to handle documents whose styles we don't recognize.
	static func headingLevel(forStyleIdentifier identifier: String) -> Int? {
		guard let range = identifier.range(of: "paragraphstyle-") else { return nil }
		let suffix = String(identifier[range.upperBound...])
		if suffix == "Title" { return 1 }
		if suffix.hasPrefix("Heading ") { return Int(suffix.dropFirst(8)).map { min(max($0, 1), 6) } }
		if suffix == "Heading" { return 1 }
		return nil
	}

	/// Reads the character-style run table, resolving each run's referenced
	/// character style to its bold/italic/strikethrough flags and whether it is set
	/// in a monospace font (which we surface as inline `code`).
	private func characterRuns(_ storage: IWAObject, store: IWAObjectStore) -> [(index: Int, bold: Bool, italic: Bool, strike: Bool, code: Bool)] {
		guard let table = ProtobufMessage(storage.payload).message(IWork.charStyleTableField) else { return [] }
		var runs = [(index: Int, bold: Bool, italic: Bool, strike: Bool, code: Bool)]()
		for entry in table.messages(IWork.runEntryField) {
			guard let index = entry.varint(IWork.runCharIndexField) else { continue }
			var bold = false
			var italic = false
			var strike = false
			var code = false
			if let reference = entry.message(IWork.runStyleRefField),
			   let styleID = reference.varint(IWork.referenceIdentifierField),
			   let styleObject = store.object(styleID),
			   let charProperties = ProtobufMessage(styleObject.payload).message(IWork.charPropertiesField) {
				bold = (charProperties.varint(IWork.boldField) ?? 0) != 0
				italic = (charProperties.varint(IWork.italicField) ?? 0) != 0
				strike = (charProperties.varint(IWork.strikethroughField) ?? 0) != 0
				if let font = charProperties.bytes(IWork.fontNameField).map({ String(decoding: $0, as: UTF8.self) }) {
					code = Self.isMonospaceFont(font)
				}
			}
			runs.append((index: Int(index), bold: bold, italic: italic, strike: strike, code: code))
		}
		runs.sort { $0.index < $1.index }
		return runs
	}

	/// Whether a PostScript font name denotes a monospace family (so its run is
	/// surfaced as inline code). Covers the writer's `Menlo-Regular` plus the common
	/// monospace fonts a real document might use.
	static func isMonospaceFont(_ font: String) -> Bool {
		let lower = font.lowercased()
		return ["menlo", "courier", "monaco", "consol", "mono", "andale", "pt mono", "ibm plex mono", "sfmono", "sf mono"].contains { lower.contains($0) }
	}

	/// Reads the smart-field run table (`#11`) into hyperlink spans over the global
	/// text, resolving each range to its `TSWP` hyperlink object's destination URL.
	/// A run with a reference opens a link; the next run (reference or end) closes it.
	private func linkRuns(_ storage: IWAObject, store: IWAObjectStore) -> [(start: Int, end: Int, url: String)] {
		guard let table = ProtobufMessage(storage.payload).message(IWork.smartFieldTableField) else { return [] }
		var marks = [(index: Int, url: String?)]()
		for entry in table.messages(IWork.runEntryField) {
			guard let index = entry.varint(IWork.runCharIndexField) else { continue }
			var url: String?
			if let reference = entry.message(IWork.runStyleRefField),
			   let objectID = reference.varint(IWork.referenceIdentifierField),
			   let hyperlink = store.object(objectID),
			   let bytes = ProtobufMessage(hyperlink.payload).bytes(IWork.hyperlinkURLField) {
				url = String(decoding: bytes, as: UTF8.self)
			}
			marks.append((Int(index), url))
		}
		marks.sort { $0.index < $1.index }
		var spans = [(start: Int, end: Int, url: String)]()
		for (i, mark) in marks.enumerated() where mark.url != nil {
			let end = i + 1 < marks.count ? marks[i + 1].index : mark.index
			if end > mark.index { spans.append((mark.index, end, mark.url!)) }
		}
		return spans
	}

	/// Extracts a footnote storage's content as a single trimmed line (the leading
	/// footnote-mark object replacement character is dropped, soft breaks become
	/// spaces).
	private func footnoteText(_ storage: IWAObject) -> String {
		let message = ProtobufMessage(storage.payload)
		var text = ""
		for chunk in message.allBytes(IWork.textField) {
			text += String(decoding: chunk, as: UTF8.self)
		}
		return text
			.replacingOccurrences(of: "\u{FFFC}", with: "")
			.replacingOccurrences(of: "\u{2028}", with: " ")
			.replacingOccurrences(of: "\n", with: " ")
			.replacingOccurrences(of: "\t", with: " ")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Finds footnote reference marks in the body: run-table entries whose
	/// reference resolves to a footnote-content storage. Scans every run table so
	/// it doesn't depend on the table's field number.
	private func footnoteRuns(_ storage: IWAObject, footnoteStorageIDs: Set<UInt64>, store: IWAObjectStore) -> [(index: Int, storageID: UInt64)] {
		var out = [(index: Int, storageID: UInt64)]()
		for field in ProtobufMessage(storage.payload).fields {
			guard case .lengthDelimited(let bytes) = field.value else { continue }
			for entry in ProtobufMessage(bytes).messages(IWork.runEntryField) {
				guard let index = entry.varint(IWork.runCharIndexField),
				      let reference = entry.message(IWork.runStyleRefField),
				      let markID = reference.varint(IWork.referenceIdentifierField),
				      let storageID = resolveFootnoteStorage(markID, footnoteStorageIDs: footnoteStorageIDs, store: store) else { continue }
				out.append((index: Int(index), storageID: storageID))
			}
		}
		out.sort { $0.index < $1.index }
		return out
	}

	/// Follows a footnote-mark object's references to the footnote-content storage.
	private func resolveFootnoteStorage(_ objectID: UInt64, footnoteStorageIDs: Set<UInt64>, store: IWAObjectStore, depth: Int = 0) -> UInt64? {
		if footnoteStorageIDs.contains(objectID) { return objectID }
		guard depth < 3, let object = store.object(objectID) else { return nil }
		for field in ProtobufMessage(object.payload).fields {
			if case .lengthDelimited(let bytes) = field.value,
			   let next = ProtobufMessage(bytes).varint(1) {
				if footnoteStorageIDs.contains(next) { return next }
				if store.object(next) != nil,
				   let resolved = resolveFootnoteStorage(next, footnoteStorageIDs: footnoteStorageIDs, store: store, depth: depth + 1) {
					return resolved
				}
			}
		}
		return nil
	}

	/// Reads the per-paragraph list indent level from the para-data run table.
	private func listLevels(_ storage: IWAObject) -> [(index: Int, level: Int)] {
		guard let table = ProtobufMessage(storage.payload).message(IWork.paraDataTableField) else { return [] }
		var out = [(index: Int, level: Int)]()
		for entry in table.messages(IWork.runEntryField) {
			guard let index = entry.varint(IWork.runCharIndexField) else { continue }
			out.append((index: Int(index), level: Int(entry.varint(IWork.listLevelField) ?? 0)))
		}
		out.sort { $0.index < $1.index }
		return out
	}

	/// Reads the list-style run table: `(character index, list-style identifier)`.
	private func listStyleRuns(_ storage: IWAObject) -> [(index: Int, styleID: UInt64)] {
		guard let table = ProtobufMessage(storage.payload).message(IWork.listStyleTableField) else { return [] }
		var out = [(index: Int, styleID: UInt64)]()
		for entry in table.messages(IWork.runEntryField) {
			guard let index = entry.varint(IWork.runCharIndexField),
			      let reference = entry.message(IWork.runStyleRefField),
			      let styleID = reference.varint(IWork.referenceIdentifierField) else { continue }
			out.append((index: Int(index), styleID: styleID))
		}
		out.sort { $0.index < $1.index }
		return out
	}

	/// Determines whether the paragraph at a character index is a list item, and
	/// if so its nesting level and whether it is ordered.
	private func listMembership(atUTF16 index: Int, levels: [(index: Int, level: Int)], listStyles: [(index: Int, styleID: UInt64)], store: IWAObjectStore) -> (level: Int?, ordered: Bool) {
		guard let styleID = lastValue(in: listStyles.map { (index: $0.index, value: $0.styleID) }, atOrBefore: index) else {
			return (nil, false)
		}
		let level = lastValue(in: levels.map { (index: $0.index, value: $0.level) }, atOrBefore: index) ?? 0
		switch resolveListMarker(styleID, level: level, store: store) {
		case .none:
			return (nil, false)
		case .bullet:
			return (level, false)
		case .ordered:
			return (level, true)
		}
	}

	/// The marker a list style defines at a level, following the parent chain for
	/// anonymous styles that inherit it.
	private func resolveListMarker(_ styleID: UInt64, level: Int, store: IWAObjectStore, depth: Int = 0) -> ListMarker {
		guard depth < 8, let object = store.object(styleID) else { return .none }
		let message = ProtobufMessage(object.payload)
		let markers = message.allVarints(IWork.listMarkerTypeField)
		if !markers.isEmpty {
			let value = markers[min(max(level, 0), markers.count - 1)]
			if value == IWork.listOrderedMarker { return .ordered }
			return value == 0 ? .none : .bullet
		}
		if let base = message.message(IWork.listStyleBaseField),
		   let parent = base.message(IWork.listStyleParentField),
		   let parentID = parent.varint(IWork.referenceIdentifierField) {
			return resolveListMarker(parentID, level: level, store: store, depth: depth + 1)
		}
		return .none
	}

	/// The value of the last run entry whose index is `<=` the given offset.
	private func lastValue<Value>(in runs: [(index: Int, value: Value)], atOrBefore offset: Int) -> Value? {
		var result: Value?
		for run in runs {
			guard run.index <= offset else { break }
			result = run.value
		}
		return result
	}
}
