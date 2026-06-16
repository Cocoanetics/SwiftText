import Foundation

/// Horizontal text alignment of a table column (from the Markdown delimiter row).
enum PagesColumnAlignment: Equatable {
	case left, center, right
	/// The `TSWP.ParagraphStylePropertiesArchive.alignment` (#1) value Pages uses for
	/// an explicit override (empirically: right = 1, center = 2; left needs no style).
	var paragraphValue: UInt64 { self == .right ? 1 : 2 }
}

/// A table destined for native iWork (`TST`) rendering: a rectangular grid of
/// already-flattened cell strings, row-major, with the first row as the header.
struct PagesTable {
	let rows: Int
	let columns: Int
	/// `rows * columns` cell strings, row-major (row 0 = header row).
	let cells: [String]
	/// Per-cell inline style runs, parallel to `cells`. A cell with any non-plain run
	/// becomes a rich-text cell; an empty list means a plain string cell.
	var cellRuns: [[BodyParagraph.StyledRun]] = []
	/// Per-column horizontal alignment (count == `columns`). Defaults to all-left.
	var alignments: [PagesColumnAlignment] = []

	// MARK: Comprehensive table model (programmatic styling)

	/// Per-cell appearance overrides (fill / borders / vertical alignment / wrap), keyed
	/// by row-major cell index. Each distinct appearance becomes a `CellStyleArchive`.
	var cellAppearances: [Int: PagesCellAppearance] = [:]
	/// Per-column widths in points (empty → captured default for every column).
	var columnWidths: [Float] = []
	/// Per-row heights in points (empty → captured default for every row).
	var rowHeights: [Float] = []
	/// Number of header rows (default 1), header columns (default 0), footer rows (default 0).
	var headerRows = 1
	var headerColumns = 0
	var footerRows = 0
	/// A visible table title shown above the grid (`nil` = hidden, the default for
	/// Markdown tables). Realised as `TableModelArchive` `#8` text + `#22` enabled.
	var title: String?

	func alignment(ofColumn column: Int) -> PagesColumnAlignment {
		column < alignments.count ? alignments[column] : .left
	}
	/// The inline runs for a cell, or `[]` (plain) when none were provided.
	func runs(ofCell index: Int) -> [BodyParagraph.StyledRun] {
		index < cellRuns.count ? cellRuns[index].filter { $0.length > 0 && !$0.style.isPlain } : []
	}
	/// The non-empty appearance for a cell, or `nil`.
	func appearance(ofCell index: Int) -> PagesCellAppearance? {
		guard let a = cellAppearances[index], !a.isEmpty else { return nil }
		return a
	}
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
	/// Per styleTable component id: the synthesized alignment-style object ids it
	/// references (in `DocumentStylesheet`). The writer adds matching `ComponentInfo`
	/// `#6` cross-references so Pages can resolve them.
	var styleComponentRefs: [UInt64: [UInt64]] = [:]
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

	// Cell text alignment (see PAGES_WRITING.md). A cell's tile-record word W1 keys
	// into the styleTable (`DataList` 1733212) → a paragraph style whose `#12 #1` is
	// the alignment override. Header/body need different bold/regular parent bases.
	static let styleTableID: UInt64 = 1733212
	static let defaultCellStyleID: UInt64 = 1734364   // captured cell para style (left header, key 1)
	static let headerCellBaseStyleID: UInt64 = 1731526 // "Table Style 1" (bold) — header parent
	static let bodyCellBaseStyleID: UInt64 = 1731527   // "Table Style 2" (regular) — body parent
	static let stylesheetID: UInt64 = 1732613
	/// A base-template default body cell style (`CellStyleArchive` 6004 in
	/// `DocumentStylesheet`); the parent for synthesized per-cell appearance styles.
	static let defaultBodyCellStyleID: UInt64 = 1731720
	/// Base id for synthesized per-table alignment paragraph styles (well above the
	/// captured/relocated table id ranges and below the synthesized char-style range).
	static let alignmentStyleBase: UInt64 = 5_000_000
	/// Base id for synthesized per-table cell-appearance styles (`CellStyleArchive`).
	static let appearanceStyleBase: UInt64 = 5_100_000

	/// Per-table styling: the regenerated styleTable, the synthesized style objects (for
	/// `DocumentStylesheet`), per-column alignment keys, and per-cell appearance keys.
	/// `styleObjects` mixes `2022` paragraph styles (alignment) and `6004` cell styles
	/// (appearance); the record loop appends each with its own type.
	struct Styling {
		var styleTable: [UInt8]
		var styleObjects: [(id: UInt64, payload: [UInt8], parent: UInt64, type: UInt64)]
		var headerKeys: [Int]   // per column: style key for the header cell (≥1)
		var bodyKeys: [Int]     // per column: style key for the body cell (0 = unstyled/left)
		/// Per column: the paragraph-style object id a *rich* cell's storage should use
		/// so it inherits the column's alignment (base style for left, the synthesized
		/// alignment style for center/right). Header and body rows differ in base style.
		var headerParaStyleIDs: [UInt64]
		var bodyParaStyleIDs: [UInt64]
		/// Per cell index: a style key for the cell's appearance (`CellStyleArchive`),
		/// overriding the column alignment key for that cell.
		var cellAppearanceKeys: [Int: Int] = [:]
		var maxObjectID: UInt64
	}

	/// Computes the alignment styling for a table. Left columns reuse the default
	/// (key 1 header / unstyled body); center/right columns get synthesized styles.
	static func styling(for table: PagesTable, offset: UInt64, tableIndex: Int) -> Styling {
		var entries: [(key: Int, ref: UInt64)] = [(1, defaultCellStyleID)]  // relocated by the record loop
		var styleObjects: [(UInt64, [UInt8], UInt64, UInt64)] = []
		var nextKey = 2
		var nextSynth = alignmentStyleBase + UInt64(tableIndex) * 64
		var cache: [String: Int] = [:]
		var synthStyleID: [String: UInt64] = [:]
		func key(for alignment: PagesColumnAlignment, header: Bool) -> Int {
			if alignment == .left { return header ? 1 : 0 }
			let cacheKey = "\(alignment)-\(header)"
			if let existing = cache[cacheKey] { return existing }
			let parent = header ? headerCellBaseStyleID : bodyCellBaseStyleID
			let styleID = nextSynth; nextSynth += 1
			styleObjects.append((styleID, alignmentParagraphStyle(parent: parent, alignment: alignment), parent, 2022))
			synthStyleID[cacheKey] = styleID
			let k = nextKey; nextKey += 1
			entries.append((k, styleID))
			cache[cacheKey] = k
			return k
		}
		var headerKeys = [Int](), bodyKeys = [Int]()
		var headerParaStyleIDs = [UInt64](), bodyParaStyleIDs = [UInt64]()
		for column in 0..<table.columns {
			let alignment = table.alignment(ofColumn: column)
			headerKeys.append(key(for: alignment, header: true))
			bodyKeys.append(key(for: alignment, header: false))
			// The paragraph style a rich cell's storage uses to inherit alignment.
			headerParaStyleIDs.append(alignment == .left ? headerCellBaseStyleID : synthStyleID["\(alignment)-true"] ?? headerCellBaseStyleID)
			bodyParaStyleIDs.append(alignment == .left ? bodyCellBaseStyleID : synthStyleID["\(alignment)-false"] ?? bodyCellBaseStyleID)
		}

		// Per-cell appearance (fill / borders / vertical alignment / wrap) → a
		// `CellStyleArchive` (6004) referenced by the cell's W1 key, overriding alignment.
		var cellAppearanceKeys = [Int: Int]()
		var appearanceCache = [PagesCellAppearance: Int]()
		var nextAppearance = appearanceStyleBase + UInt64(tableIndex) * 256
		for index in table.cells.indices {
			guard let appearance = table.appearance(ofCell: index), appearance.hasCellProperties else { continue }
			if let existing = appearanceCache[appearance] { cellAppearanceKeys[index] = existing; continue }
			let styleID = nextAppearance; nextAppearance += 1
			styleObjects.append((styleID, cellStyleArchive(appearance, parent: defaultBodyCellStyleID), defaultBodyCellStyleID, 6004))
			let k = nextKey; nextKey += 1
			entries.append((k, styleID))
			appearanceCache[appearance] = k
			cellAppearanceKeys[index] = k
		}

		return Styling(styleTable: buildStyleTable(entries), styleObjects: styleObjects,
		               headerKeys: headerKeys, bodyKeys: bodyKeys,
		               headerParaStyleIDs: headerParaStyleIDs, bodyParaStyleIDs: bodyParaStyleIDs,
		               cellAppearanceKeys: cellAppearanceKeys,
		               maxObjectID: max(nextSynth, nextAppearance) - 1)
	}

	/// A `TSP.Color` in the RGB "model 1" form Pages uses for fills and strokes.
	static func tspColor(_ c: PagesColor) -> TSP_Color {
		var tsp = TSP_Color(); tsp.model = 1
		tsp.r = c.red; tsp.g = c.green; tsp.b = c.blue; tsp.a = c.alpha
		return tsp
	}
	/// A solid `TSD.StrokeArchive` (color + width). The solid `pattern` is required or
	/// Pages renders nothing.
	static func strokeArchive(_ border: PagesCellBorder) -> TSD_StrokeArchive {
		var s = TSD_StrokeArchive(); s.color = tspColor(border.color); s.width = border.width
		s.cap = 0; s.join = 0                          // butt cap, miter join
		var pattern = TSD_StrokePatternArchive()
		pattern.type = 1                               // TSDSolidPattern
		pattern.phase = 0; pattern.count = 0
		s.pattern = pattern
		return s
	}

	/// Builds a `TST.CellStyleArchive` (6004) for a cell appearance via the generated
	/// wire models: `super` parents to a base cell style, `cell_properties` carries the
	/// fill / vertical alignment / wrap. Lives in `DocumentStylesheet`. Borders are NOT
	/// here — Pages paints cell borders from the table stroke sidecar (see `strokeSidecar`).
	static func cellStyleArchive(_ appearance: PagesCellAppearance, parent: UInt64) -> [UInt8] {
		var sup = TSS_StyleArchive()
		var parentRef = TSP_Reference(); parentRef.identifier = parent; sup.parent = parentRef
		sup.isVariation = true
		var sheetRef = TSP_Reference(); sheetRef.identifier = stylesheetID; sup.stylesheet = sheetRef

		var props = TST_CellStylePropertiesArchive()
		if let fill = appearance.fill { var f = TSD_FillArchive(); f.color = tspColor(fill); props.cellFill = f }
		if let valign = appearance.verticalAlignment { props.verticalAlignment = valign.rawValue }
		if let wrap = appearance.textWrap { props.textWrap = wrap }

		var cellStyle = TST_CellStyleArchive()
		cellStyle.super = sup
		cellStyle.overrideCount = 1
		cellStyle.cellProperties = props
		return cellStyle.encoded()
	}

	// MARK: Cell borders — the table stroke sidecar (StrokeSidecarArchive 6305)

	/// The captured table's `stroke_sidecar` (model `#49`), regenerated to carry borders.
	static let strokeSidecarID: UInt64 = 1733259
	/// Base id for synthesized per-table stroke layers (`StrokeLayerArchive` 6306).
	static let strokeLayerBase: UInt64 = 5_500_000

	/// A regenerated `StrokeSidecarArchive` (6305) plus its `StrokeLayerArchive` (6306)
	/// objects, built from the table's per-cell borders. Pages organizes cell borders as
	/// run-length stroke layers per grid line — one layer per row/column edge, each a list
	/// of `{origin, length, stroke}` runs — not per cell.
	struct StrokeSidecar {
		var sidecar: [UInt8]
		var layers: [(id: UInt64, payload: [UInt8])]
		var layerIDs: [UInt64]
		var maxObjectID: UInt64
	}

	/// Builds the stroke sidecar for a table's cell borders, or `nil` if none.
	static func strokeSidecar(for table: PagesTable, tableIndex: Int) -> StrokeSidecar? {
		let C = table.columns
		// side → grid-line index → [(perpendicular index, border)]
		var top = [Int: [(Int, PagesCellBorder)]](), bottom = [Int: [(Int, PagesCellBorder)]]()
		var left = [Int: [(Int, PagesCellBorder)]](), right = [Int: [(Int, PagesCellBorder)]]()
		for index in table.cells.indices {
			guard let ap = table.appearance(ofCell: index), ap.hasBorders else { continue }
			let r = index / C, c = index % C
			if let b = ap.topBorder { top[r, default: []].append((c, b)) }
			if let b = ap.bottomBorder { bottom[r, default: []].append((c, b)) }
			if let b = ap.leftBorder { left[c, default: []].append((r, b)) }
			if let b = ap.rightBorder { right[c, default: []].append((r, b)) }
		}
		guard !(top.isEmpty && bottom.isEmpty && left.isEmpty && right.isEmpty) else { return nil }

		var layers = [(id: UInt64, payload: [UInt8])]()
		var nextLayer = strokeLayerBase + UInt64(tableIndex) * 256
		var order: UInt32 = 1
		func buildLayers(_ map: [Int: [(Int, PagesCellBorder)]]) -> [UInt64] {
			var ids = [UInt64]()
			for (lineIndex, runs) in map.sorted(by: { $0.key < $1.key }) {
				var layer = TST_StrokeLayerArchive()
				layer.rowColumnIndex = UInt32(lineIndex)
				for (origin, border) in runs.sorted(by: { $0.0 < $1.0 }) {
					var run = TST_StrokeLayerArchive_StrokeRunArchive()
					run.origin = Int32(origin); run.length = 1
					run.stroke = strokeArchive(border); run.order = order; order += 1
					layer.strokeRuns.append(run)
				}
				let id = nextLayer; nextLayer += 1
				layers.append((id, layer.encoded()))
				ids.append(id)
			}
			return ids
		}
		let leftIDs = buildLayers(left), rightIDs = buildLayers(right)
		let topIDs = buildLayers(top), bottomIDs = buildLayers(bottom)
		func refs(_ ids: [UInt64]) -> [TSP_Reference] { ids.map { var r = TSP_Reference(); r.identifier = $0; return r } }

		var sidecar = TST_StrokeSidecarArchive()
		sidecar.maxOrder = order
		sidecar.columnCount = UInt32(table.columns)
		sidecar.rowCount = UInt32(table.rows)
		sidecar.leftColumnStrokeLayers = refs(leftIDs)
		sidecar.rightColumnStrokeLayers = refs(rightIDs)
		sidecar.topRowStrokeLayers = refs(topIDs)
		sidecar.bottomRowStrokeLayers = refs(bottomIDs)
		let allIDs = leftIDs + rightIDs + topIDs + bottomIDs
		return StrokeSidecar(sidecar: sidecar.encoded(), layers: layers, layerIDs: allIDs, maxObjectID: nextLayer - 1)
	}

	/// `DataStore.styleTable` (`DataList` list-id 4): `#1` listid=4, `#2` maxKey+1,
	/// repeated `#3 { #1 key, #2 refcount, #4 { #1 styleRef } }`.
	static func buildStyleTable(_ entries: [(key: Int, ref: UInt64)]) -> [UInt8] {
		var w = ProtobufWriter()
		w.varintField(1, 4)
		w.varintField(2, UInt64((entries.map(\.key).max() ?? 0) + 1))
		for entry in entries {
			var ref = ProtobufWriter(); ref.varintField(1, entry.ref)
			var body = ProtobufWriter()
			body.varintField(1, UInt64(entry.key))
			body.varintField(2, 1)
			body.bytesField(4, ref.bytes)
			w.bytesField(3, body.bytes)
		}
		return w.bytes
	}

	/// A `TSWP.ParagraphStyleArchive` (2022) that overrides only the alignment:
	/// `#1` super (parent base style + stylesheet), `#12` para_properties `#1` = align.
	static func alignmentParagraphStyle(parent: UInt64, alignment: PagesColumnAlignment) -> [UInt8] {
		var parentRef = ProtobufWriter(); parentRef.varintField(1, parent)
		var stylesheetRef = ProtobufWriter(); stylesheetRef.varintField(1, stylesheetID)
		var styleSuper = ProtobufWriter()
		styleSuper.bytesField(3, parentRef.bytes)
		styleSuper.varintField(4, 1)
		styleSuper.bytesField(5, stylesheetRef.bytes)
		var paraProperties = ProtobufWriter()
		paraProperties.varintField(1, alignment.paragraphValue)
		var w = ProtobufWriter()
		w.bytesField(1, styleSuper.bytes)   // super
		w.varintField(10, 1)                // #10 (present on built-in styles)
		w.bytesField(11, [])                // #11 char_properties (empty)
		w.bytesField(12, paraProperties.bytes)
		return w.bytes
	}

	// MARK: Rich-text cells (in-cell bold/italic)

	static let richTextTableID: UInt64 = 1733197
	static let noneCharStyleID: UInt64 = 1731539
	static let listNoneStyleID: UInt64 = 1731481
	/// Base ids for synthesized per-table cell storages (2001) and cell char styles (2021).
	static let cellStorageBase: UInt64 = 5_300_000
	static let cellCharStyleBase: UInt64 = 5_200_000
	static let cellWrapperBase: UInt64 = 5_400_000

	/// The rich-text content for a table: regenerated string + rich_text_table
	/// payloads, the cell storages (for the rich_text_table component file) and char
	/// styles (for `DocumentStylesheet`), per-cell plans (plain string key vs rich
	/// key), and the styles the rich_text_table component must cross-reference.
	struct RichContent {
		var cellStrings: [UInt8]
		var richTextTable: [UInt8]
		var storageRecords: [[UInt8]]
		var storageIDs: [UInt64]
		var charStyleRecords: [(id: UInt64, payload: [UInt8])]
		var cellPlans: [(isRich: Bool, key: Int)]
		var crossRefStyleIDs: [UInt64]
		var maxObjectID: UInt64
	}

	/// Splits a table's cells into plain (string DataList) and rich (a `TSWP`
	/// StorageArchive + char styles, keyed through the rich_text_table) and builds
	/// every object Pages needs for in-cell bold/italic.
	static func richContent(for table: PagesTable, offset: UInt64, tableIndex: Int, styling: Styling) -> RichContent {
		let C = table.columns
		var plans = [(isRich: Bool, key: Int)]()
		var stringEntries = [(key: Int, string: String)]()
		var richEntries = [(key: Int, wrapperID: UInt64)]()
		var storageRecords = [[UInt8]]()
		var charStyleRecords = [(UInt64, [UInt8])]()
		var crossRefs = Set<UInt64>()
		var nextStringKey = 1, nextRichKey = 1
		var nextStorage = cellStorageBase + UInt64(tableIndex) * 4096
		var nextCharStyle = cellCharStyleBase + UInt64(tableIndex) * 256
		var charStyleByStyle = [InlineStyle: UInt64]()
		func charStyleID(_ style: InlineStyle) -> UInt64 {
			if let existing = charStyleByStyle[style] { return existing }
			let id = nextCharStyle; nextCharStyle += 1
			charStyleRecords.append((id, cellCharacterStyle(style)))
			charStyleByStyle[style] = id
			crossRefs.insert(id)
			return id
		}
		var nextWrapper = cellWrapperBase + UInt64(tableIndex) * 4096
		for index in table.cells.indices {
			let runs = table.runs(ofCell: index)
			if runs.isEmpty {
				plans.append((false, nextStringKey))
				stringEntries.append((nextStringKey, table.cells[index]))
				nextStringKey += 1
			} else {
				let isHeader = index < C
				let column = index % C
				// Inherit the column's alignment via the storage's own paragraph style
				// (base style for left columns, the synthesized alignment style otherwise).
				let paraStyle = isHeader
					? (column < styling.headerParaStyleIDs.count ? styling.headerParaStyleIDs[column] : headerCellBaseStyleID)
					: (column < styling.bodyParaStyleIDs.count ? styling.bodyParaStyleIDs[column] : bodyCellBaseStyleID)
				let storageID = nextStorage; nextStorage += 1
				let wrapperID = nextWrapper; nextWrapper += 1
				let (payload, refs) = cellStorage(text: table.cells[index], runs: runs, paraStyle: paraStyle, charStyleID: charStyleID)
				// Both the 2001 storage and its 6218 wrapper live in the rich_text_table
				// component; the entry points at the wrapper, the wrapper at the storage.
				storageRecords.append(recordWithReferences(id: storageID, type: 2001, version: [0x01, 0x00, 0x05], payload: payload, references: refs))
				storageRecords.append(recordWithReferences(id: wrapperID, type: 6218, version: [0x01, 0x00, 0x05], payload: cellTextWrapper(storageID: storageID), references: [storageID]))
				crossRefs.formUnion([paraStyle, listNoneStyleID])
				richEntries.append((nextRichKey, wrapperID))
				plans.append((true, nextRichKey))
				nextRichKey += 1
			}
		}
		return RichContent(
			cellStrings: buildKeyedStrings(stringEntries),
			richTextTable: buildRichTextTable(richEntries),
			storageRecords: storageRecords,
			storageIDs: richEntries.map(\.wrapperID),
			charStyleRecords: charStyleRecords.map { ($0.0, $0.1) },
			cellPlans: plans,
			crossRefStyleIDs: Array(crossRefs).sorted(),
			maxObjectID: max(nextStorage, max(nextWrapper, nextCharStyle)) &- 1
		)
	}

	/// Cell-string DataList from explicit `(key, string)` entries (only plain cells).
	static func buildKeyedStrings(_ entries: [(key: Int, string: String)]) -> [UInt8] {
		var w = ProtobufWriter()
		w.varintField(1, 1)
		w.varintField(2, UInt64((entries.map(\.key).max() ?? 0) + 1))
		for entry in entries {
			var cell = ProtobufWriter()
			cell.varintField(1, UInt64(entry.key)); cell.varintField(2, 1); cell.stringField(3, entry.string)
			w.bytesField(3, cell.bytes)
		}
		return w.bytes
	}

	/// `DataStore.rich_text_table` (`DataList` list-id 8): entry
	/// `{ #1 key, #2 1, #9 { #1 storageRef } }` → a cell text storage.
	static func buildRichTextTable(_ entries: [(key: Int, wrapperID: UInt64)]) -> [UInt8] {
		var w = ProtobufWriter()
		w.varintField(1, 8)
		w.varintField(2, UInt64((entries.map(\.key).max() ?? 0) + 1))
		for entry in entries {
			var ref = ProtobufWriter(); ref.varintField(1, entry.wrapperID)
			var body = ProtobufWriter()
			body.varintField(1, UInt64(entry.key)); body.varintField(2, 1); body.bytesField(9, ref.bytes)
			w.bytesField(3, body.bytes)
		}
		return w.bytes
	}

	/// A `TSWP.StorageArchive` (2001, kind 5 = cell): `#3` text + `#8` char-style run
	/// table over the inline runs. Returns the payload and the object ids it references.
	static func cellStorage(text: String, runs: [BodyParagraph.StyledRun], paraStyle: UInt64, charStyleID: (InlineStyle) -> UInt64) -> (payload: [UInt8], references: [UInt64]) {
		// Char-style run table: a partition starting unstyled at 0, then each run's
		// style and a bare entry back to unstyled (same shape as the body's #8). A run
		// extends to the next entry's index, so the closing "back to unstyled" entry is
		// only needed when plain text follows. An entry at index == text length is past
		// the last character — Pages discards the whole run table if one is present, so
		// such entries are filtered out below.
		let textLength = text.utf16.count
		var entries: [(index: Int, styleID: UInt64?)] = [(0, nil)]
		var referencedStyles = [UInt64]()
		for run in runs.sorted(by: { $0.start < $1.start }) {
			let id = charStyleID(run.style)
			referencedStyles.append(id)
			entries.append((run.start, id))
			entries.append((run.start + run.length, nil))
		}
		entries = normalizedRuns(entries).filter { $0.index < textLength }
		var writer = ProtobufWriter()
		writer.varintField(1, 5)                                  // kind = cell
		writer.bytesField(2, reference(stylesheetID))             // style ref
		writer.bytesField(3, Array(text.utf8))                    // text
		writer.bytesField(5, runTable([(0, paraStyle)]))          // para-style
		writer.bytesField(6, paragraphDataTable())                // para-data
		writer.bytesField(7, runTable([(0, listNoneStyleID)]))    // list-style
		writer.bytesField(8, runTable(entries))                   // char-style
		writer.varintField(10, 1)
		writer.bytesField(14, paragraphDataTable())
		writer.bytesField(24, paragraphDataTable())
		return (writer.bytes, [paraStyle, listNoneStyleID] + referencedStyles)
	}

	/// A 2021 character style overriding only char_properties (bold/italic/code/...).
	static func cellCharacterStyle(_ style: InlineStyle) -> [UInt8] {
		var styleSuper = ProtobufWriter()
		styleSuper.bytesField(3, reference(noneCharStyleID))
		styleSuper.varintField(4, 1)
		styleSuper.bytesField(5, reference(stylesheetID))
		var charProperties = ProtobufWriter()
		if style.bold { charProperties.varintField(1, 1) }
		if style.italic { charProperties.varintField(2, 1) }
		if style.code { charProperties.stringField(5, "Menlo-Regular") }
		if style.link { charProperties.varintField(11, 1) }
		if style.strikethrough { charProperties.varintField(12, 1) }
		var w = ProtobufWriter()
		w.bytesField(1, styleSuper.bytes)
		w.varintField(10, 1)
		w.bytesField(11, charProperties.bytes)
		return w.bytes
	}

	/// A cell text wrapper (type 6218): `#1` references the cell's 2001 text storage,
	/// `#3` is a full-range descriptor captured verbatim (sentinel "whole range" max
	/// bounds: fixed32 0x00ffffff + a `{ #2 0x7fff, #3 0x7fffffff }` sub-range). The
	/// rich_text_table entry points at this wrapper, which in turn points at the storage.
	private static func cellTextWrapper(storageID: UInt64) -> [UInt8] {
		var w = ProtobufWriter()
		w.bytesField(1, reference(storageID))
		w.bytesField(3, [0x0d, 0xff, 0xff, 0xff, 0x00, 0x12, 0x0a, 0x10, 0xff, 0xff, 0x01, 0x18, 0xff, 0xff, 0xff, 0xff, 0x07])
		return w.bytes
	}

	/// A 24-byte rich-text cell: flags `05 09`, SW `10 10 02 00` (has-rich-id), and the
	/// rich_text_table key at byte 12.
	private static func richCell(richKey: Int) -> [UInt8] {
		[0x05, 0x09, 0, 0, 0, 0, 0, 0] + [0x10, 0x10, 0x02, 0x00] + u32le(richKey) + [0x05, 0, 0, 0, 0x01, 0, 0, 0]
	}

	private static func reference(_ id: UInt64) -> [UInt8] { var w = ProtobufWriter(); w.varintField(1, id); return w.bytes }
	private static func runTable(_ entries: [(index: Int, styleID: UInt64?)]) -> [UInt8] {
		var w = ProtobufWriter()
		for entry in entries {
			var e = ProtobufWriter(); e.varintField(1, UInt64(entry.index))
			if let styleID = entry.styleID { e.bytesField(2, reference(styleID)) }
			w.bytesField(1, e.bytes)
		}
		return w.bytes
	}
	private static func paragraphDataTable() -> [UInt8] {
		var e = ProtobufWriter(); e.varintField(1, 0); e.varintField(2, 0); e.varintField(3, 0)
		var w = ProtobufWriter(); w.bytesField(1, e.bytes); return w.bytes
	}
	/// Merges run entries at the same index (last wins) and drops no-op changes.
	private static func normalizedRuns(_ entries: [(index: Int, styleID: UInt64?)]) -> [(index: Int, styleID: UInt64?)] {
		var byIndex = [(index: Int, styleID: UInt64?)]()
		for entry in entries {
			if let last = byIndex.last, last.index == entry.index { byIndex[byIndex.count - 1].styleID = entry.styleID }
			else { byIndex.append(entry) }
		}
		var result = [(index: Int, styleID: UInt64?)]()
		for entry in byIndex { if let last = result.last, last.styleID == entry.styleID { continue }; result.append(entry) }
		return result
	}
	/// Frames a cell storage (2001) record with its object_references (#5).
	private static func storageRecord(id: UInt64, payload: [UInt8], references: [UInt64]) -> [UInt8] {
		recordWithReferences(id: id, type: 2001, version: [0x01, 0x00, 0x05], payload: payload, references: references)
	}

	/// Frames an object record whose `MessageInfo` carries the version (`#2`) and the
	/// `object_references` (`#5`) Pages uses to resolve references — without `#5` the
	/// referenced parent/styles aren't linked and the styling is silently dropped.
	static func recordWithReferences(id: UInt64, type: UInt64, version: [UInt8], payload: [UInt8], references: [UInt64]) -> [UInt8] {
		var messageInfo = ProtobufWriter()
		messageInfo.varintField(1, type)
		messageInfo.bytesField(2, version)
		messageInfo.varintField(3, UInt64(payload.count))
		if !references.isEmpty { messageInfo.packedVarintField(5, references) }
		var archiveInfo = ProtobufWriter(); archiveInfo.varintField(1, id); archiveInfo.bytesField(2, messageInfo.bytes)
		var out = ProtobufWriter.varint(UInt64(archiveInfo.bytes.count))
		out.append(contentsOf: archiveInfo.bytes)
		out.append(contentsOf: payload)
		return out
	}

	/// A synthesized paragraph (2022) or character (2021) style record whose `#5`
	/// object_references list its parent — required or Pages drops the inheritance.
	static func styleRecord(id: UInt64, payload: [UInt8], parent: UInt64, type: UInt64 = 2022) -> [UInt8] {
		recordWithReferences(id: id, type: type, version: [0x01, 0x00, 0x05], payload: payload, references: [parent])
	}

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
			let styling = styling(for: table, offset: offset, tableIndex: tableIndex)
			let rich = richContent(for: table, offset: offset, tableIndex: tableIndex, styling: styling)
			let borders = strokeSidecar(for: table, tableIndex: tableIndex)
			artifacts.maxObjectID = max(artifacts.maxObjectID, rich.maxObjectID)
			if let borders { artifacts.maxObjectID = max(artifacts.maxObjectID, borders.maxObjectID) }
			// Regenerate the dimension-dependent payloads (with base-table references,
			// offset below alongside every cloned object).
			var rewritten: [UInt64: [UInt8]] = [
				PagesTableTemplate.columnRowUIDsID: buildColumnRowUIDs(rows: R, columns: C),
				PagesTableTemplate.tileID: buildTile(rows: R, columns: C, styling: styling, cellPlans: rich.cellPlans),
				PagesTableTemplate.cellStringsID: rich.cellStrings,
				PagesTableTemplate.modelID: patchModel(try record(PagesTableTemplate.modelID).payloadOnly, rows: R, columns: C, name: table.title ?? "Table \(tableIndex + 1)", titleVisible: table.title != nil, headerRows: table.headerRows, headerColumns: table.headerColumns, footerRows: table.footerRows),
				PagesTableTemplate.rowHeadersBucketID: buildBucket(try record(PagesTableTemplate.rowHeadersBucketID).payloadOnly, count: R, otherDimension: C, size: rowHeight, sizes: table.rowHeights),
				PagesTableTemplate.columnHeadersBucketID: buildBucket(try record(PagesTableTemplate.columnHeadersBucketID).payloadOnly, count: C, otherDimension: R, size: columnWidth, sizes: table.columnWidths),
				PagesTableTemplate.tableInfoID: hideTitleAndCaption(try record(PagesTableTemplate.tableInfoID).payloadOnly, titleHidden: table.title == nil),
				styleTableID: styling.styleTable,
			]
			if !rich.storageRecords.isEmpty { rewritten[richTextTableID] = rich.richTextTable }
			if let borders { rewritten[strokeSidecarID] = borders.sidecar }

			for entry in records {
				artifacts.maxObjectID = max(artifacts.maxObjectID, entry.id + offset)
				// `Index/Metadata.iwa` (PackageMetadata + shared-object map) is supplied
				// wholesale from the captured template, so skip its delta records here —
				// appending them would duplicate the shared-object-map object.
				if entry.file == "Index/Metadata.iwa" { continue }
				let recordBytes = try record(entry.id)
				let payload = rewritten[entry.id] ?? recordBytes.payloadOnly
				// A regenerated styleTable / rich_text_table must list (in its
				// object_references) the styles / storages it now points at, or Pages
				// won't resolve them through the table.
				let objectReferences: [UInt64]? = entry.id == styleTableID
					? [defaultCellStyleID + offset] + styling.styleObjects.map(\.id)
					: (entry.id == richTextTableID && !rich.storageRecords.isEmpty
						? rich.storageIDs
						: (entry.id == strokeSidecarID ? borders?.layerIDs : nil))
				let finalRecord = relocateRecord(recordBytes, newPayload: payload, offset: offset, objectReferences: objectReferences)
				if entry.file.hasPrefix("Index/Tables/") {
					let path = offset == 0 ? entry.file : relocatedTablePath(entry.file, newID: entry.id + offset)
					// Cell text storages live in the rich_text_table's component file.
					var stream = finalRecord
					if entry.id == richTextTableID { for storage in rich.storageRecords { stream.append(contentsOf: storage) } }
					artifacts.newFiles[path] = [UInt8](IWAArchive.encode(stream: stream))
				} else {
					appendStreams[entry.file, default: []].append(contentsOf: finalRecord)
					// Stroke layers live in the sidecar's component (CalculationEngine).
					if entry.id == strokeSidecarID, let borders {
						for layer in borders.layers {
							appendStreams[entry.file, default: []].append(contentsOf: recordWithReferences(id: layer.id, type: 6306, version: [0x01, 0x00, 0x05], payload: layer.payload, references: []))
						}
					}
				}
			}
			// Synthesized alignment paragraph styles (2022) and cell-appearance styles
			// (6004) live in DocumentStylesheet; their ids are final (not relocated).
			for style in styling.styleObjects {
				appendStreams["Index/DocumentStylesheet.iwa", default: []].append(contentsOf: styleRecord(id: style.id, payload: style.payload, parent: style.parent, type: style.type))
				artifacts.maxObjectID = max(artifacts.maxObjectID, style.id)
			}
			for charStyle in rich.charStyleRecords {
				appendStreams["Index/DocumentStylesheet.iwa", default: []].append(contentsOf: styleRecord(id: charStyle.id, payload: charStyle.payload, parent: noneCharStyleID, type: 2021))
			}
			if !styling.styleObjects.isEmpty {
				artifacts.styleComponentRefs[styleTableID + offset] = styling.styleObjects.map(\.id)
			}
			if !rich.crossRefStyleIDs.isEmpty {
				artifacts.styleComponentRefs[richTextTableID + offset] = rich.crossRefStyleIDs
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
	static func buildTile(rows R: Int, columns C: Int, styling: Styling = Styling(styleTable: [], styleObjects: [], headerKeys: [], bodyKeys: [], headerParaStyleIDs: [], bodyParaStyleIDs: [], maxObjectID: 0), cellPlans: [(isRich: Bool, key: Int)] = []) -> [UInt8] {
		var w = ProtobufWriter()
		w.varintField(1, 0); w.varintField(2, 0); w.varintField(3, 0)   // maxColumn/maxRow/numCells
		w.varintField(4, UInt64(R))                                     // numrows
		for r in 0..<R { w.bytesField(5, tileRow(r, columns: C, styling: styling, cellPlans: cellPlans)) }
		w.varintField(6, 5)                                             // storage_version (constant)
		w.varintField(7, 1)                                             // last_saved_in_BNC
		return w.bytes
	}

	private static func tileRow(_ row: Int, columns C: Int, styling: Styling, cellPlans: [(isRich: Bool, key: Int)]) -> [UInt8] {
		let columnMeta = (0..<C).flatMap { _ -> [UInt8] in [0x04, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] }
		let metaOffsets = (0..<C).map { $0 * 12 }
		var cells = [UInt8]()
		var cellStarts = [Int]()
		for c in 0..<C {
			cellStarts.append(cells.count)
			let index = row * C + c
			let plan = index < cellPlans.count ? cellPlans[index] : (isRich: false, key: index + 1)
			if plan.isRich {
				cells.append(contentsOf: richCell(richKey: plan.key))
			} else if let appearanceKey = styling.cellAppearanceKeys[index] {
				// A per-cell appearance (fill/border/v-align) overrides the column alignment.
				cells.append(contentsOf: appearanceCell(key: plan.key, styleKey: appearanceKey))
			} else if row == 0 {
				let styleKey = c < styling.headerKeys.count ? styling.headerKeys[c] : 1
				cells.append(contentsOf: styledCell(key: plan.key, styleKey: styleKey))
			} else {
				let styleKey = c < styling.bodyKeys.count ? styling.bodyKeys[c] : 0
				cells.append(contentsOf: styleKey == 0 ? bodyCell(key: plan.key) : styledCell(key: plan.key, styleKey: styleKey))
			}
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

	/// A 28-byte string cell that carries a styleTable key in W1 (SW `0x48` sets the
	/// `0x40` *paragraph*-style bit). `styleKey` 1 = the default cell style; >1 = an
	/// alignment paragraph style.
	private static func styledCell(key: Int, styleKey: Int) -> [UInt8] {
		[0x05, 0x03, 0, 0, 0, 0, 0, 0] + [0x48, 0x10, 0x02, 0x00] + u32le(key) + u32le(styleKey) + [0x05, 0, 0, 0, 0x01, 0, 0, 0]
	}
	/// A 28-byte string cell whose W1 keys a *cell* style (SW `0x28`, the `0x20`
	/// cell-style bit) rather than a paragraph style — for fill / border / vertical
	/// alignment overrides (`CellStyleArchive`). Same layout as ``styledCell``.
	private static func appearanceCell(key: Int, styleKey: Int) -> [UInt8] {
		[0x05, 0x03, 0, 0, 0, 0, 0, 0] + [0x28, 0x10, 0x02, 0x00] + u32le(key) + u32le(styleKey) + [0x05, 0, 0, 0, 0x01, 0, 0, 0]
	}
	/// A 24-byte string cell with no style key (SW `0x08`) — left-aligned body default.
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
	/// rows, `#10` header columns, `#11` footer rows, `#22` table_name_enabled = 0
	/// (Markdown tables have no visible title; the programmatic model keeps that default).
	static func patchModel(_ payload: [UInt8], rows R: Int, columns C: Int, name: String, titleVisible: Bool = false,
	                       headerRows: Int = 1, headerColumns: Int = 0, footerRows: Int = 0) -> [UInt8] {
		// Header + footer rows can't overlap or exceed the row count.
		let hr = max(0, min(headerRows, R))
		let fr = max(0, min(footerRows, R - hr))
		let hc = max(0, min(headerColumns, C))
		let model = ProtobufMessage(payload)
		var w = ProtobufWriter()
		var wroteHeaderColumns = false, wroteFooterRows = false, wroteNameEnabled = false
		for field in model.fields {
			switch field.number {
			case 6: w.varintField(6, UInt64(R))
			case 7: w.varintField(7, UInt64(C))
			case 8: w.stringField(8, name)
			case 9: w.varintField(9, UInt64(hr))
			case 10: w.varintField(10, UInt64(hc)); wroteHeaderColumns = true
			case 11: w.varintField(11, UInt64(fr)); wroteFooterRows = true
			case 22: w.varintField(22, titleVisible ? 1 : 0); wroteNameEnabled = true
			default: w.append(field)
			}
		}
		if !wroteHeaderColumns { w.varintField(10, UInt64(hc)) }
		if !wroteFooterRows, fr > 0 { w.varintField(11, UInt64(fr)) }
		if !wroteNameEnabled { w.varintField(22, titleVisible ? 1 : 0) }
		return w.bytes
	}

	/// `TableInfoArchive` (6000): hide the table title and caption by setting the
	/// `super` (`TSD.DrawableArchive`) `#12` title_hidden and `#13` caption_hidden —
	/// Markdown tables carry neither. Other drawable fields (geometry, the title and
	/// caption storages) are preserved.
	static func hideTitleAndCaption(_ payload: [UInt8], titleHidden: Bool = true, captionHidden: Bool = true) -> [UInt8] {
		let info = ProtobufMessage(payload)
		var writer = ProtobufWriter()
		for field in info.fields {
			guard field.number == 1, case .lengthDelimited(let drawable) = field.value else { writer.append(field); continue }
			var drawableWriter = ProtobufWriter()
			var wroteTitle = false, wroteCaption = false
			for drawableField in ProtobufMessage(drawable).fields {
				switch drawableField.number {
				case 12: drawableWriter.varintField(12, titleHidden ? 1 : 0); wroteTitle = true
				case 13: drawableWriter.varintField(13, captionHidden ? 1 : 0); wroteCaption = true
				default: drawableWriter.append(drawableField)
				}
			}
			if !wroteTitle { drawableWriter.varintField(12, titleHidden ? 1 : 0) }
			if !wroteCaption { drawableWriter.varintField(13, captionHidden ? 1 : 0) }
			writer.bytesField(1, drawableWriter.bytes)
		}
		return writer.bytes
	}

	/// `HeaderStorageBucket` (row heights / column widths): `count` `Header`s
	/// `{ #1 index, #2 f32 size, #3 0, #4 otherDimension }`. The entry count is one of
	/// the grid dimensions. `sizes` gives a per-index point size; missing entries (and
	/// an empty array) fall back to the captured default `size`.
	static func buildBucket(_ payload: [UInt8], count: Int, otherDimension: Int, size: Float, sizes: [Float] = []) -> [UInt8] {
		var w = ProtobufWriter()
		w.varintField(1, 1)                                  // bucketHashFunction
		for index in 0..<count {
			var header = ProtobufWriter()
			header.varintField(1, UInt64(index))
			let entrySize = index < sizes.count && sizes[index] > 0 ? sizes[index] : size
			header.fixed32Field(2, entrySize.bitPattern)
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
	static func relocateRecord(_ recordBytes: [UInt8], newPayload payload: [UInt8], offset: UInt64, objectReferences: [UInt64]? = nil) -> [UInt8] {
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
				aiWriter.bytesField(2, relocateMessageInfo(messageInfo, payloadLength: newPayload.count, offset: offset, objectReferences: objectReferences))
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
	/// reference list. When `objectReferences` is given (e.g. a regenerated styleTable
	/// that now points at synthesized styles), `#5` is replaced with that list so Pages
	/// resolves the new references. Other fields (type, version) are preserved.
	private static func relocateMessageInfo(_ messageInfo: [UInt8], payloadLength: Int, offset: UInt64, objectReferences: [UInt64]? = nil) -> [UInt8] {
		var writer = ProtobufWriter()
		var wroteRefs = false
		for field in ProtobufMessage(messageInfo).fields {
			switch field.number {
			case 3:
				writer.varintField(3, UInt64(payloadLength))
			case 4 where offset != 0:
				guard case .lengthDelimited(let fieldInfo) = field.value else { writer.append(field); continue }
				writer.bytesField(4, relocateFieldInfo(fieldInfo, offset: offset))
			case 5:
				if let objectReferences { writer.packedVarintField(5, objectReferences); wroteRefs = true }
				else if offset != 0, case .lengthDelimited(let refs) = field.value { writer.bytesField(5, offsetPackedVarints(refs, by: offset)) }
				else { writer.append(field) }
			default:
				writer.append(field)
			}
		}
		if let objectReferences, !wroteRefs { writer.packedVarintField(5, objectReferences) }
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
	static func relocateComponentMetadata(_ payload: [UInt8], tableCount: Int, highWaterMark: UInt64, styleComponentRefs: [UInt64: [UInt64]] = [:]) -> [UInt8] {
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
					// A per-table component file: keep the original (+ any alignment-style
					// cross-references), then add an offset clone per extra table.
					writer.bytesField(3, addingStyleCrossReferences(message, styleComponentRefs: styleComponentRefs))
					for offset in offsets { writer.bytesField(3, cloneTablesComponentInfo(message, offset: offset, styleComponentRefs: styleComponentRefs)) }
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
	private static func cloneTablesComponentInfo(_ info: ProtobufMessage, offset: UInt64, styleComponentRefs: [UInt64: [UInt64]] = [:]) -> [UInt8] {
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
		// Alignment styles synthesized for this (relocated) table's styleTable.
		for styleID in styleComponentRefs[id + offset] ?? [] { writer.bytesField(6, crossReference(component: stylesheetID, object: styleID)) }
		return writer.bytes
	}

	/// Re-emits a `Tables/*` `ComponentInfo` verbatim, then appends a `#6` external
	/// reference to each synthesized alignment style its styleTable points at.
	private static func addingStyleCrossReferences(_ info: ProtobufMessage, styleComponentRefs: [UInt64: [UInt64]]) -> [UInt8] {
		let id = info.varint(1) ?? 0
		guard let styleIDs = styleComponentRefs[id] else { return reencode(info) }
		var writer = ProtobufWriter()
		for field in info.fields { writer.append(field) }
		for styleID in styleIDs { writer.bytesField(6, crossReference(component: stylesheetID, object: styleID)) }
		return writer.bytes
	}

	/// An external-reference message `{ #1 component, #2 object }`.
	private static func crossReference(component: UInt64, object: UInt64) -> [UInt8] {
		var w = ProtobufWriter(); w.varintField(1, component); w.varintField(2, object); return w.bytes
	}
	private static func reencode(_ message: ProtobufMessage) -> [UInt8] {
		var w = ProtobufWriter(); for field in message.fields { w.append(field) }; return w.bytes
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
