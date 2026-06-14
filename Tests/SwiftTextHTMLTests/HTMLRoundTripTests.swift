import Foundation
import SwiftTextHTML
import Testing

/// Round-trip stability across the two swift-markdown-backed converters:
/// `MarkdownToHTML` (Markdown→HTML) and `HTMLDocument.markdown()` (HTML→Markdown).
/// The migration makes the swift-markdown AST the shared representation for both
/// directions; these tests verify that content survives a round trip and that
/// each conversion is idempotent (a fixpoint is reached).
@Suite("HTML round-trip")
struct HTMLRoundTripTests {

	private func mdThroughHTML(_ md: String) async throws -> String {
		try await HTMLDocument(data: Data(MarkdownToHTML.convert(md).utf8)).markdown()
	}

	private func htmlThroughMD(_ html: String) async throws -> String {
		MarkdownToHTML.convert(try await HTMLDocument(data: Data(html.utf8)).markdown())
	}

	/// Canonical Markdown survives Markdown → HTML → Markdown byte-identically,
	/// and the conversion is idempotent.
	@Test func markdownToHTMLToMarkdownIsStable() async throws {
		let md = [
			"# Title", "",
			"A paragraph with **bold**, *italic*, ~strike~, `code`, and a [link](https://example.com).", "",
			"- one", "- two", "",
			"> a quote", "",
			"-----", "",
			"```", "let x = 1", "```",
		].joined(separator: "\n")

		let once = try await mdThroughHTML(md)
		#expect(once == md)                              // canonical input is a fixpoint
		#expect(try await mdThroughHTML(once) == once)   // idempotent
	}

	/// A footnote reference + definition survives the round trip.
	@Test func footnoteMarkdownRoundTrips() async throws {
		let md = "A claim[^1].\n\n[^1]: The note."
		#expect(try await mdThroughHTML(md) == md)
	}

	/// Representative HTML reaches a fixpoint through HTML → Markdown → HTML, and
	/// the structural content survives the round trip.
	@Test func htmlToMarkdownToHTMLReachesFixpoint() async throws {
		let html = "<h1>Doc</h1><p>Text <strong>b</strong> <em>i</em> <code>c</code>.</p>"
			+ "<ul><li>x</li><li>y</li></ul>"
			+ "<table><thead><tr><th>N</th><th>Q</th></tr></thead><tbody><tr><td>a</td><td>1</td></tr></tbody></table>"
			+ "<blockquote><p>q</p></blockquote>"

		let once = try await htmlThroughMD(html)
		#expect(try await htmlThroughMD(once) == once)   // idempotent

		#expect(once.contains("<h1>Doc</h1>"))
		#expect(once.contains("<strong>b</strong>"))
		#expect(once.contains("<code>c</code>"))
		#expect(once.contains("<table>"))
		#expect(once.contains("<blockquote>"))
	}
}
