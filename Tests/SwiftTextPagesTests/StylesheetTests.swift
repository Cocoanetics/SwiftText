import Foundation
import Testing

@testable import SwiftTextPages

/// Verifies the default stylesheet `MarkdownToPages` installs lives in the document's
/// *style objects* (so editing a style in Pages re-cascades to every paragraph that
/// uses it), and that text color is encoded the way Pages writes it in its own
/// templates — `model=1` (RGB), `space=1` (sRGB), `a=1` — so it actually renders.
@Suite("Pages default stylesheet")
struct StylesheetTests {
    /// Generates a document from Markdown and returns its `DocumentStylesheet.iwa`
    /// style objects keyed by object id.
    private func generatedStyles(_ markdown: String) throws -> [UInt64: IWAObject] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swifttext-style-\(UUID().uuidString).pages")
        defer { try? FileManager.default.removeItem(at: url) }
        try MarkdownToPages.convert(markdown, to: url)
        let sheet = try PagesContainer.entries(at: url, prefix: "Index/")
            .first { $0.path.hasSuffix("DocumentStylesheet.iwa") }
        let objects = try IWAArchive.objects(from: #require(sheet).data)
        return Dictionary(objects.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func charProperties(_ object: IWAObject) -> TSWP_CharacterStylePropertiesArchive? {
        TSWP_ParagraphStyleArchive(ProtobufMessage(object.payload)).charProperties
    }

    @Test("Block quote is gray, italic, and indented — in the style object, not per run")
    func blockQuoteIsGray() throws {
        let styles = try generatedStyles("> A quoted line.\n")
        let quote = try #require(styles[PagesStyleID.blockQuote])
        let para = TSWP_ParagraphStyleArchive(ProtobufMessage(quote.payload))

        // Pages RENDERS text color from the modern fill (tsdFill, char_properties #46),
        // not the legacy font_color (#7) — so the fill is what must be gray.
        let fill = try #require(para.charProperties?.tsdFill?.color)
        #expect(abs((fill.r ?? 0) - 0.4) < 0.01)
        #expect(abs((fill.g ?? 0) - 0.4) < 0.01)
        #expect(abs((fill.b ?? 0) - 0.4) < 0.01)
        #expect(fill.model == 1)           // RGB
        #expect(fill.rgbspace == 1)        // sRGB

        // The legacy font_color is kept in sync (round-trip / older readers).
        let color = try #require(para.charProperties?.fontColor)
        #expect(abs((color.r ?? 0) - 0.4) < 0.01)
        #expect(abs((color.b ?? 0) - 0.4) < 0.01)

        #expect(para.charProperties?.italic == true)
        // A real left indent lives in the paragraph properties.
        #expect(para.paraProperties != nil)
    }

    @Test("Block quote has the HTML-style left bar (a paragraph stroke on the left edge)")
    func blockQuoteHasLeftBar() throws {
        let styles = try generatedStyles("> A quoted line.\n")
        let quote = try #require(styles[PagesStyleID.blockQuote])
        let pp = try #require(TSWP_ParagraphStyleArchive(ProtobufMessage(quote.payload)).paraProperties)

        // A solid gray rule down the left edge: a stroke + the left border position,
        // the way Pages encodes a left paragraph border (RE'd from a Pages-authored quote).
        let stroke = try #require(pp.stroke)
        #expect(abs((stroke.width ?? 0) - 4) < 0.01)
        let bar = try #require(stroke.color)
        #expect(abs((bar.r ?? 0) - 0.795) < 0.01)
        #expect(abs((bar.g ?? 0) - 0.795) < 0.01)
        #expect(abs((bar.b ?? 0) - 0.795) < 0.01)
        #expect(bar.model == 1)            // RGB
        #expect(pp.borderPositions == 4)   // left edge

        // Left-aligned: a modest ~0.5cm indent, first-line and left equal (a clean block).
        #expect(abs((pp.firstLineIndent ?? 0) - 14.173) < 0.01)
        #expect(abs((pp.leftIndent ?? 0) - 14.173) < 0.01)
    }

    @Test("Code block is framed like HTML <pre> — a filled, rounded, all-edge bordered box")
    func codeBlockIsFramed() throws {
        let styles = try generatedStyles("```\nlet x = 1\n```\n")
        let code = try #require(styles[PagesStyleID.codeBlock])
        let pp = try #require(TSWP_ParagraphStyleArchive(ProtobufMessage(code.payload)).paraProperties)

        // Subtle gray background fill (RGBA, ~12% alpha) — RE'd from a Pages-authored block.
        let fill = try #require(pp.fill)
        #expect(abs((fill.r ?? 0) - 0.572) < 0.01)
        #expect(abs((fill.a ?? 1) - 0.121) < 0.01)
        #expect(fill.model == 1)
        // A thin border on all four edges (bitmask 1|2|4|8 = 15), rounded corners.
        #expect(pp.borderPositions == 15)
        #expect(pp.roundedCorners == true)
        let stroke = try #require(pp.stroke)
        #expect(abs((stroke.width ?? 0) - 0.25) < 0.01)
        // Interior padding (~0.2cm) via the left/right indents.
        #expect(abs((pp.leftIndent ?? 0) - 5.669) < 0.01)
        #expect(abs((pp.rightIndent ?? 0) - 5.669) < 0.01)
    }

    @Test("Heading 4 is rebuilt black + bold (the blank theme ships it red)")
    func headingFourIsNotRed() throws {
        let styles = try generatedStyles("#### A minor heading\n")
        let h4 = try #require(styles[PagesStyleID.heading4])
        let cp = try #require(charProperties(h4))
        let color = try #require(cp.fontColor)
        // Black, not the theme's "Heading Red" (~0.93, 0.13, 0.05).
        #expect((color.r ?? 1) < 0.01)
        #expect((color.g ?? 1) < 0.01)
        #expect((color.b ?? 1) < 0.01)
        #expect(cp.bold == true)
    }

    @Test("Code block is a dedicated monospace, colored style")
    func codeBlockStyle() throws {
        let styles = try generatedStyles("```\nlet x = 1\n```\n")
        let code = try #require(styles[PagesStyleID.codeBlock])
        let para = TSWP_ParagraphStyleArchive(ProtobufMessage(code.payload))

        // Monospace face lives in the style (no per-run override needed).
        #expect(para.charProperties?.fontName == "Menlo-Regular")
        // Code text reads as a distinct dark-red color (rendered via the fill).
        let color = try #require(para.charProperties?.tsdFill?.color)
        #expect((color.r ?? 0) > 0.5)
        #expect((color.g ?? 1) < 0.2)
        // Real margin around the framed block (the box fill itself is covered by
        // `codeBlockIsFramed`), and a named, round-trippable style.
        #expect((para.paraProperties?.spaceBefore ?? 0) > 0)
        #expect((para.paraProperties?.spaceAfter ?? 0) > 0)
        #expect(para.super?.styleIdentifier == "swifttext-code-block")
    }

    @Test("A fenced code block round-trips through .pages back to a fence")
    func codeBlockRoundTrips() throws {
        let md = "Intro.\n\n```\nfunc f() {\n    return 1\n}\n```\n\nOutro.\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swifttext-code-\(UUID().uuidString).pages")
        defer { try? FileManager.default.removeItem(at: url) }
        try MarkdownToPages.convert(md, to: url)

        let out = try PagesFile(url: url).markdown()
        #expect(out.contains("```"))                 // recovered as a fence, not plain text
        #expect(out.contains("func f() {"))
        #expect(out.contains("    return 1"))        // indentation preserved
    }

    @Test("Nested list items carry their depth in para-data #2 and round-trip indented")
    func nestedListIndents() throws {
        let md = "- One\n- Two\n  - Nested\n- Three\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swifttext-list-\(UUID().uuidString).pages")
        defer { try? FileManager.default.removeItem(at: url) }
        try MarkdownToPages.convert(md, to: url)

        // The nesting depth must live in para-data field 2 ("first") — that's where Pages
        // reads it to apply the list style's per-level indent. Field 3 stays 0.
        let entries = try PagesContainer.entries(at: url, prefix: "Index/", suffix: ".iwa")
        var store = IWAObjectStore()
        for e in entries { (try? IWAArchive.objects(from: e.data))?.forEach { store.add($0) } }
        let body = try #require(store.objects(ofType: 2001)
            .filter { ProtobufMessage($0.payload).bytes(3) != nil }
            .max { (ProtobufMessage($0.payload).bytes(3)?.count ?? 0) < (ProtobufMessage($1.payload).bytes(3)?.count ?? 0) })
        let paraData = try #require(ProtobufMessage(body.payload).message(6))
        #expect(paraData.messages(1).contains { $0.varint(2) == 1 })             // nested item: depth 1 in #2
        #expect(paraData.messages(1).allSatisfy { ($0.varint(3) ?? 0) == 0 })    // #3 always 0

        // And the nesting survives the round-trip back to Markdown.
        #expect(try PagesFile(url: url).markdown().contains("  - Nested"))
    }

    @Test("Headings carry a real size hierarchy in their style objects")
    func headingSizesCascade() throws {
        let styles = try generatedStyles("# H1\n## H2\n### H3\n\nBody.\n")
        func size(_ id: UInt64) throws -> Float {
            let object = try #require(styles[id])
            return try #require(charProperties(object)?.fontSize)
        }
        let h1 = try size(PagesStyleID.heading1)
        let h2 = try size(PagesStyleID.heading2)
        let h3 = try size(PagesStyleID.heading3)
        #expect(h1 > h2)
        #expect(h2 > h3)
        #expect(h1 == 24)
    }
}
