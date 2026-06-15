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
		/// Within a para-data entry: the list indent level.
		static let listLevelField = 3
		/// `TSP.Reference.identifier`.
		static let referenceIdentifierField = 1
		/// Char/paragraph `…StyleArchive.char_properties`.
		static let charPropertiesField = 11
		/// Within char properties: bold, italic, strikethrough, and font size.
		static let boldField = 1
		static let italicField = 2
		static let strikethroughField = 12
		static let fontSizeField = 3
		/// `ListStyleArchive` — base style (field 1), whose parent reference
		/// (field 3) supports inheritance, and the per-level marker type (field 11:
		/// 0 = none, 2 = bullet, 3 = numbered).
		static let listStyleBaseField = 1
		static let listStyleParentField = 3
		static let listMarkerTypeField = 11
		static let listBulletMarker: UInt64 = 2
		static let listOrderedMarker: UInt64 = 3
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
		let footnoteRefs = footnoteStorageIDs.isEmpty
			? []
			: footnoteRuns(storage, footnoteStorageIDs: footnoteStorageIDs, store: store)
		var result = [PagesDocument.Paragraph]()
		// Paragraph separators are \n / U+2029; soft breaks (U+2028) stay inside a
		// paragraph. Run-table character indices are UTF-16 offsets (Cocoa text),
		// so offsets are tracked in UTF-16 units.
		var current = String.UnicodeScalarView()
		var currentAttachments = [String?]()
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

		func flush() {
			let paragraphText = String(current)
			let style = resolvedStyle(atUTF16: paragraphStartUTF16, runs: runs, store: store)
			let (listLevel, listOrdered) = listMembership(atUTF16: paragraphStartUTF16, levels: levels, listStyles: listStyles, store: store)
			result.append(PagesDocument.Paragraph(
				text: paragraphText,
				fontSize: style.fontSize,
				bold: style.bold,
				attachmentReferences: currentAttachments,
				emphasis: currentEmphasis,
				listLevel: listLevel,
				listOrdered: listOrdered,
				footnoteMarkers: currentFootnotes
			))
			current = String.UnicodeScalarView()
			currentAttachments = []
			currentEmphasis = []
			currentFootnotes = []
		}

		for scalar in text.unicodeScalars {
			while charRunIndex < charRuns.count, charRuns[charRunIndex].index <= utf16Offset {
				activeBold = charRuns[charRunIndex].bold
				activeItalic = charRuns[charRunIndex].italic
				activeStrike = charRuns[charRunIndex].strike
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
				}
				if currentEmphasis.isEmpty || currentEmphasis.last?.bold != activeBold
					|| currentEmphasis.last?.italic != activeItalic || currentEmphasis.last?.strike != activeStrike {
					currentEmphasis.append(.init(start: utf16Offset - paragraphStartUTF16, bold: activeBold, italic: activeItalic, strike: activeStrike))
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

	/// Finds the style active at a character index, then resolves its font size
	/// and bold flag from the referenced paragraph-style object.
	private func resolvedStyle(atUTF16 index: Int, runs: [(index: Int, styleID: UInt64?)], store: IWAObjectStore) -> (fontSize: Double?, bold: Bool) {
		var activeStyleID: UInt64?
		for run in runs {
			guard run.index <= index else { break }
			if let styleID = run.styleID { activeStyleID = styleID }
		}
		guard let activeStyleID, let styleObject = store.object(activeStyleID) else {
			return (nil, false)
		}
		let style = ProtobufMessage(styleObject.payload)
		guard let charProperties = style.message(IWork.charPropertiesField) else {
			return (nil, false)
		}
		let bold = (charProperties.varint(IWork.boldField) ?? 0) != 0
		let fontSize = charProperties.float(IWork.fontSizeField).map(Double.init)
		return (fontSize, bold)
	}

	/// Reads the character-style run table, resolving each run's referenced
	/// character style to its bold/italic/strikethrough flags.
	private func characterRuns(_ storage: IWAObject, store: IWAObjectStore) -> [(index: Int, bold: Bool, italic: Bool, strike: Bool)] {
		guard let table = ProtobufMessage(storage.payload).message(IWork.charStyleTableField) else { return [] }
		var runs = [(index: Int, bold: Bool, italic: Bool, strike: Bool)]()
		for entry in table.messages(IWork.runEntryField) {
			guard let index = entry.varint(IWork.runCharIndexField) else { continue }
			var bold = false
			var italic = false
			var strike = false
			if let reference = entry.message(IWork.runStyleRefField),
			   let styleID = reference.varint(IWork.referenceIdentifierField),
			   let styleObject = store.object(styleID),
			   let charProperties = ProtobufMessage(styleObject.payload).message(IWork.charPropertiesField) {
				bold = (charProperties.varint(IWork.boldField) ?? 0) != 0
				italic = (charProperties.varint(IWork.italicField) ?? 0) != 0
				strike = (charProperties.varint(IWork.strikethroughField) ?? 0) != 0
			}
			runs.append((index: Int(index), bold: bold, italic: italic, strike: strike))
		}
		runs.sort { $0.index < $1.index }
		return runs
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
