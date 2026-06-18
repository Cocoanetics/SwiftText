import Foundation
import SwiftTextHTML
import Testing

/// HTML→Markdown footnote restoration. swift-markdown has no footnote node, so
/// `DOMMarkupConverter` reconstructs `[^id]` references and `[^id]: …` definitions
/// from recognized footnote structures (`DOMFootnoteIndex`). Detection is layered:
/// generator-attribute fast-path plus an attribute-free structural fallback.
@Suite("HTML footnote conversion")
struct HTMLFootnoteConversionTests {

	private func markdown(_ html: String) async throws -> String {
		try await HTMLDocument(data: Data(html.utf8)).markdown()
	}

	/// MD → HTML (via the project's own footnote renderer) → MD restores footnote
	/// syntax. Labels are the renderer-assigned sequence (`[^n]` became `[^2]`),
	/// which is the correct footnote numbering, and inline emphasis survives.
	@Test func projectFootnotesRoundTrip() async throws {
		let source = "A claim[^1] and another[^n].\n\n[^1]: First definition.\n[^n]: Second, with *emphasis*."
		let restored = try await markdown(MarkdownToHTML.convert(source))

		let expected = [
			"A claim[^1] and another[^2].",
			"",
			"[^1]: First definition.",
			"",
			"[^2]: Second, with *emphasis*."
		].joined(separator: "\n")
		#expect(restored == expected)
	}

	/// GitHub/GFM-rendered footnotes (`data-footnote-ref`, `<section data-footnotes>`,
	/// `↩` backref). The backref is dropped and the definition body is clean.
	@Test func githubFootnotesRestored() async throws {
		let html = """
		<p>Text with a ref<sup><a href="#user-content-fn-1" id="user-content-fnref-1" data-footnote-ref>1</a></sup>.</p>
		<section data-footnotes class="footnotes"><ol>
		<li id="user-content-fn-1"><p>The footnote body. <a href="#user-content-fnref-1" data-footnote-backref>↩</a></p></li>
		</ol></section>
		"""
		let restored = try await markdown(html)
		#expect(restored == "Text with a ref[^1].\n\n[^1]: The footnote body.")
	}

	/// Pandoc-rendered footnotes (`role="doc-noteref"`, `<sup>` inside the `<a>`,
	/// `role="doc-endnotes"` section with a leading `<hr>`).
	@Test func pandocFootnotesRestored() async throws {
		let html = """
		<p>Claim<a href="#fn1" class="footnote-ref" id="fnref1" role="doc-noteref"><sup>1</sup></a>.</p>
		<section class="footnotes" role="doc-endnotes"><hr>
		<ol><li id="fn1"><p>Pandoc note.<a href="#fnref1" class="footnote-back" role="doc-backlink">↩</a></p></li></ol>
		</section>
		"""
		let restored = try await markdown(html)
		#expect(restored == "Claim[^1].\n\n[^1]: Pandoc note.")
	}

	/// Attribute-free detection: no `class`/`role`/`data-*` markers at all — only
	/// numeric `#href` references whose targets reciprocally link back. The leading
	/// `<hr>` before the definition list is suppressed too.
	@Test func handRolledFootnotesWithoutAttributes() async throws {
		let html = """
		<p>Claim<sup><a href="#note1" id="ref-note1">1</a></sup> and more<sup><a href="#note2" id="ref-note2">2</a></sup>.</p>
		<hr>
		<ol>
		<li id="note1">First note. <a href="#ref-note1">↩</a></li>
		<li id="note2">Second note. <a href="#ref-note2">↩</a></li>
		</ol>
		"""
		let restored = try await markdown(html)

		let expected = [
			"Claim[^1] and more[^2].",
			"",
			"[^1]: First note.",
			"",
			"[^2]: Second note."
		].joined(separator: "\n")
		#expect(restored == expected)
	}

	/// Negative test: a table of contents (numeric in-page links to headings) must
	/// NOT be mistaken for footnotes — the targets don't link back, aren't list
	/// items, and don't echo the marker.
	@Test func tableOfContentsIsNotMistakenForFootnotes() async throws {
		let html = """
		<ol><li><a href="#s1">1</a> Intro</li><li><a href="#s2">2</a> Methods</li></ol>
		<h2 id="s1">Intro</h2><p>Body one.</p><h2 id="s2">Methods</h2><p>Body two.</p>
		"""
		let restored = try await markdown(html)

		#expect(!restored.contains("[^"))
		#expect(restored.contains("## Intro"))
		#expect(restored.contains("## Methods"))
	}
}
