import Foundation

/// Builds the iWork object graph for native (page-bottom) footnotes.
///
/// Reverse-engineered by inserting a footnote in Pages and dissecting the save: each
/// footnote is a **content storage** (`TSWP.StorageArchive` type 2001 with kind=2)
/// holding the note text, referenced from the body by a **mark** (type 2008) the body's
/// `#16` reference run table anchors at a character index. The note's own number glyph is
/// an **internal mark** (type 2004) anchored in the storage's `#9` run table at a leading
/// `U+FFFC`. The note paragraph uses the template's built-in **Footnote** paragraph style.
///
/// The footnote *registry* Pages also writes (types 10132/10133/10147) lives in
/// `Index/ViewState.iwa` — it's view state, not rendering data, and Pages rebuilds it on
/// open, so we omit it. These objects go into `Index/Document.iwa` alongside the body.
enum PagesFootnoteBuilder {
    /// Template style ids the footnote objects reference (all ship in the blank template).
    private static let stylesheetID: UInt64 = 1732613
    private static let footnoteParaStyleID: UInt64 = 1731522   // "Footnote" paragraph style
    private static let noneListStyleID: UInt64 = 1731481       // "None" list style
    private static let noneCharStyleID: UInt64 = 1731539       // "None" character style
    /// Object ids for synthesized footnote objects (above images at 6.5M).
    static let objectBase: UInt64 = 6_600_000

    struct Artifacts {
        /// New objects (one shared char style + per-footnote storage/marks) for Document.iwa.
        let objects: [IWAObject]
        /// The body mark id for each footnote, in order — the body `#16` run table anchors
        /// each at its character index.
        let bodyMarkIDs: [UInt64]
        /// The shared footnote-mark character style — the body applies it (via #8) to the
        /// `U+000E` reference character so the superscript number renders.
        let charStyleID: UInt64
        let maxObjectID: UInt64
    }

    /// Builds the objects for `footnotes` (note texts, in reference order).
    static func build(_ footnotes: [String]) -> Artifacts {
        var objects = [IWAObject]()
        var bodyMarkIDs = [UInt64]()
        var next = objectBase

        // One shared footnote-mark character style.
        let charStyleID = next; next += 1
        objects.append(IWAObject(identifier: charStyleID, type: 2021, payload: markCharStyle()))

        for text in footnotes {
            let storageID = next; next += 1
            let bodyMarkID = next; next += 1
            let internalMarkID = next; next += 1
            objects.append(IWAObject(identifier: storageID, type: 2001,
                                     payload: contentStorage(text: text, charStyleID: charStyleID, internalMarkID: internalMarkID)))
            objects.append(IWAObject(identifier: bodyMarkID, type: 2008, payload: bodyMark(storageID: storageID)))
            objects.append(IWAObject(identifier: internalMarkID, type: 2004, payload: internalMark()))
            bodyMarkIDs.append(bodyMarkID)
        }
        return Artifacts(objects: objects, bodyMarkIDs: bodyMarkIDs, charStyleID: charStyleID, maxObjectID: next - 1)
    }

    // MARK: Object payloads

    private static func reference(_ id: UInt64) -> [UInt8] { var w = ProtobufWriter(); w.varintField(1, id); return w.bytes }

    /// A run-table entry `{#1: charIndex, #2: {#1: refID}}`.
    private static func runEntry(_ index: UInt64, _ refID: UInt64) -> [UInt8] {
        var w = ProtobufWriter(); w.varintField(1, index); w.bytesField(2, reference(refID)); return w.bytes
    }
    /// A single-entry run table.
    private static func runTable(_ index: UInt64, _ refID: UInt64) -> [UInt8] {
        var w = ProtobufWriter(); w.bytesField(1, runEntry(index, refID)); return w.bytes
    }

    /// The footnote content storage (type 2001, kind=2).
    private static func contentStorage(text: String, charStyleID: UInt64, internalMarkID: UInt64) -> [UInt8] {
        var w = ProtobufWriter()
        w.varintField(1, 2)                                  // kind = footnote
        w.bytesField(2, reference(stylesheetID))             // #2 stylesheet
        w.bytesField(3, Array("\u{FFFC} \(text)".utf8))      // #3 text: mark anchor + note text
        w.bytesField(5, runTable(0, footnoteParaStyleID))    // #5 paragraph style → Footnote
        w.bytesField(7, runTable(0, noneListStyleID))        // #7 list style → None
        // #8 char-style run: the mark glyph at 0 uses the footnote char style, then bare.
        var charRuns = ProtobufWriter()
        charRuns.bytesField(1, runEntry(0, charStyleID))
        var bare = ProtobufWriter(); bare.varintField(1, 1)
        charRuns.bytesField(1, bare.bytes)
        w.bytesField(8, charRuns.bytes)
        w.bytesField(6, zeroRun())                           // #6 para-data
        w.bytesField(9, runTable(0, internalMarkID))         // #9 footnote-mark → internal mark
        w.varintField(10, 1)
        w.bytesField(14, zeroRun())                          // #14
        w.bytesField(19, languageRun())                      // #19 language
        w.bytesField(24, zeroRun())                          // #24
        return w.bytes
    }

    /// A run table with a single all-zero entry `{#1:{#1:0,#2:0,#3:0}}`.
    private static func zeroRun() -> [UInt8] {
        var entry = ProtobufWriter(); entry.varintField(1, 0); entry.varintField(2, 0); entry.varintField(3, 0)
        var w = ProtobufWriter(); w.bytesField(1, entry.bytes); return w.bytes
    }
    /// The language run table Pages writes on footnote storages.
    private static func languageRun() -> [UInt8] {
        var w = ProtobufWriter()
        var e0 = ProtobufWriter(); e0.varintField(1, 0); w.bytesField(1, e0.bytes)
        var e1 = ProtobufWriter(); e1.varintField(1, 2); e1.stringField(2, "en"); w.bytesField(1, e1.bytes)
        return w.bytes
    }

    /// Body reference mark (type 2008): `{#2: {#1: storageID}}`.
    private static func bodyMark(storageID: UInt64) -> [UInt8] {
        var w = ProtobufWriter(); w.bytesField(1, []); w.bytesField(2, reference(storageID)); return w.bytes
    }

    /// Internal number mark (type 2004): `{#2: 2}` — verbatim from Pages.
    private static func internalMark() -> [UInt8] {
        var w = ProtobufWriter(); w.bytesField(1, []); w.varintField(2, 2); return w.bytes
    }

    /// The footnote-mark character style (type 2021) — a variation of the None style.
    private static func markCharStyle() -> [UInt8] {
        var sup = ProtobufWriter()
        sup.bytesField(3, reference(noneCharStyleID))        // parent = None char style
        sup.varintField(4, 1)                                // is variation
        sup.bytesField(5, reference(stylesheetID))
        var w = ProtobufWriter()
        w.bytesField(1, sup.bytes)
        w.varintField(10, 1)
        var props = ProtobufWriter(); props.varintField(10, 1)
        w.bytesField(11, props.bytes)
        return w.bytes
    }

    /// Builds the body's `#16` footnote-reference run table from `(charIndex, bodyMarkID)`
    /// pairs (sorted by index). Returns the table message bytes, or nil if empty.
    static func bodyReferenceTable(_ entries: [(index: Int, markID: UInt64)]) -> [UInt8]? {
        guard !entries.isEmpty else { return nil }
        var w = ProtobufWriter()
        for entry in entries.sorted(by: { $0.index < $1.index }) {
            w.bytesField(1, runEntry(UInt64(entry.index), entry.markID))
        }
        return w.bytes
    }
}
