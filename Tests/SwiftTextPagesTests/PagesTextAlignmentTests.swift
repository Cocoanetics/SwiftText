import Foundation
import Testing

@testable import SwiftTextPages
import SwiftTextIWA
import SwiftTextMarkdown

/// `text-align` from a stylesheet (`p`, `li`) on the Body style and list items.
@Suite("Pages paragraph alignment")
struct PagesTextAlignmentTests {
	/// The paragraph styles of a generated document: the stylesheet's and the ones the
	/// writer synthesized in `Document.iwa`, keyed by object id.
	private func styles(_ markdown: String, alignment: MarkdownTextAlignment) throws -> [UInt64: TSWP_ParagraphStyleArchive] {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-align-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		try MarkdownToPages.convert(markdown, to: url, textAlignment: alignment)
		var styles = [UInt64: TSWP_ParagraphStyleArchive]()
		for entry in try IWAContainer.entries(at: url, prefix: "Index/")
		where entry.path.hasSuffix("DocumentStylesheet.iwa") || entry.path.hasSuffix("Document.iwa") {
			for object in try IWAArchive.objects(from: entry.data) where object.type == 2022 {
				styles[object.identifier] = TSWP_ParagraphStyleArchive(ProtobufMessage(object.payload))
			}
		}
		return styles
	}

	private func alignment(_ style: TSWP_ParagraphStyleArchive?) -> Int32? { style?.paraProperties?.alignment }

	@Test("Justified paragraphs set the Body and Block Quote styles; headings, code and alert boxes keep theirs")
	func justifiesBodyStyle() throws {
		let markdown = "# Title\n\nText.\n\n> Quote.\n\n> [!NOTE]\n> Box.\n\n```\ncode\n```\n"
		let plain = try styles(markdown, alignment: .none)
		let styles = try styles(markdown, alignment: MarkdownTextAlignment(paragraph: .justify, listItem: .justify))
		#expect(alignment(styles[PagesStyleID.body]) == 3)
		#expect(alignment(styles[PagesStyleID.blockQuote]) == 3)
		for id in [PagesStyleID.heading1, PagesStyleID.calloutBody, PagesStyleID.calloutTitle, PagesStyleID.codeBlock, PagesStyleID.rule] {
			#expect(alignment(styles[id]) == alignment(plain[id]))
		}
		// List items share Body's alignment, so they need no variation.
		#expect(!styles.values.contains { $0.paraProperties?.alignment != nil && $0.super?.isVariation == true })
	}

	@Test("List items aligned unlike paragraphs get a variation of their style")
	func listItemVariation() throws {
		let styles = try styles("Text.\n\n- Item\n", alignment: MarkdownTextAlignment(paragraph: .justify))
		#expect(alignment(styles[PagesStyleID.body]) == 3)
		// An `li` takes nothing from the `p` rule: list items stay left-aligned.
		#expect(styles.values.contains { $0.super?.isVariation == true && $0.paraProperties?.alignment == 0 })
	}

	@Test("Without a stylesheet alignment nothing changes")
	func untouchedByDefault() throws {
		let styles = try styles("Text.\n\n- Item\n", alignment: .none)
		#expect(alignment(styles[PagesStyleID.body]) != 3)
	}
}
