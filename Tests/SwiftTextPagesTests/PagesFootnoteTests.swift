import Foundation
import Testing

@testable import SwiftTextPages
import SwiftTextIWA

@Suite("Pages native footnotes")
struct PagesFootnoteTests {
    @Test("A Markdown footnote becomes a native (page-bottom) footnote and round-trips")
    func footnoteEmbedsAndRoundTrips() throws {
        let md = "Body text[^1] and more.\n\n[^1]: The note text.\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swifttext-fn-\(UUID().uuidString).pages")
        defer { try? FileManager.default.removeItem(at: url) }
        try MarkdownToPages.convert(md, to: url)

        // The native footnote object graph is present: a kind-2 content storage plus the
        // body reference mark (2008) and the in-note number mark (2004).
        let entries = try IWAContainer.entries(at: url, prefix: "Index/", suffix: ".iwa")
        var store = IWAObjectStore()
        for e in entries { (try? IWAArchive.objects(from: e.data))?.forEach { store.add($0) } }
        let footnoteStorages = store.objects(ofType: 2001).filter { ProtobufMessage($0.payload).varint(1) == 2 }
        #expect(footnoteStorages.count == 1)
        #expect(store.objects(ofType: 2008).count >= 1)
        #expect(store.objects(ofType: 2004).count >= 1)
        // The note storage carries the text (after the leading U+FFFC mark anchor).
        let noteText = String(bytes: ProtobufMessage(footnoteStorages[0].payload).bytes(3) ?? [], encoding: .utf8) ?? ""
        #expect(noteText.contains("The note text."))

        // Round-trips back to Markdown cleanly — the reference becomes `[^1]` again with
        // no leftover U+000E reference character.
        let out = try PagesFile(url: url).markdown()
        #expect(out.contains("[^1]"))
        #expect(out.contains("The note text."))
        #expect(!out.contains("\u{000E}"))
    }

    @Test("Footnote definitions (incl. indented continuations) are pulled from the source")
    func extractsDefinitions() {
        let (cleaned, defs) = MarkdownPagesBuilder.extractFootnoteDefinitions(
            "A ref.\n\n[^x]: First line.\n    continued line.\n")
        #expect(defs["x"] == "First line. continued line.")
        #expect(!cleaned.contains("[^x]:"))
    }
}
