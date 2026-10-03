import Foundation
import SwiftTextHTML
import SwiftTextMarkdown
import Testing

@Suite("Alert boxes in HTML: rendering and back to Markdown")
struct HTMLAlertTests {
	@Test("A custom title and a custom kind render as an aside with that title")
	func customTitleAndKind() {
		let html = SwiftMarkdownHTMLRenderer.convert("> [!WARNING] Watch out\n> Careful.\n\n> [!EXAMPLE]\n> A letter.")
		#expect(html.contains(#"<aside class="markdown-alert markdown-alert-warning" data-alert="warning" role="note">"#))
		#expect(html.contains(#"<p class="markdown-alert-title">Watch out</p>"#))
		#expect(html.contains("<p>Careful.</p>"))
		#expect(html.contains(#"<aside class="markdown-alert markdown-alert-example" data-alert="example" role="note">"#))
		#expect(html.contains(#"<p class="markdown-alert-title">Example</p>"#))
	}

	@Test("The default stylesheet carries the shared alert CSS")
	func stylesheetCarriesAlertCSS() {
		#expect(MarkdownToHTML.defaultStylesheet.contains(MarkdownAlertLayout.css))
	}

	@Test("SwiftText's own aside reads back as the same alert")
	func asideReadsBack() async throws {
		let markdown = "> [!WARNING] Watch out\n> Careful."
		let html = SwiftMarkdownHTMLRenderer.convert(markdown)
		let back = try await HTMLDocument(data: Data(html.utf8)).markdown()
		#expect(back.contains("> [!WARNING] Watch out"))
		#expect(back.contains("> Careful."))
	}

	@Test("GitHub's alert markup (a div with an icon in the title) reads back as an alert")
	func githubMarkupReadsBack() async throws {
		let html = """
		<div class="markdown-alert markdown-alert-tip"><p class="markdown-alert-title"><svg aria-hidden="true"></svg>Tip</p><p>Helpful advice.</p></div>
		"""
		let back = try await HTMLDocument(data: Data(html.utf8)).markdown()
		#expect(back.contains("> [!TIP]"))
		#expect(!back.contains("Tip\n"))
		#expect(back.contains("> Helpful advice."))
	}
}
