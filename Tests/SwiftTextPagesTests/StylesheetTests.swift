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

    @Test("Code block is a dedicated monospace style with a background fill")
    func codeBlockStyle() throws {
        let styles = try generatedStyles("```\nlet x = 1\n```\n")
        let code = try #require(styles[PagesStyleID.codeBlock])
        let para = TSWP_ParagraphStyleArchive(ProtobufMessage(code.payload))

        // Monospace face lives in the style (no per-run override needed).
        #expect(para.charProperties?.fontName == "Menlo-Regular")
        // A paragraph background fill (shading) — the "pre" look.
        #expect(para.paraProperties?.fill != nil)
        // Named so it's editable in Pages and recognizable on round-trip.
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
