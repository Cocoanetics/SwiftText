import ArgumentParser
import Foundation
import Testing
@testable import SwiftTextCLI

@Suite("render input validation")
struct RenderInputValidationTests {
	@Test("an .html or .htm input is rejected with a clear error", arguments: ["page.html", "/tmp/PAGE.HTM"])
	func rejectsHTML(path: String) {
		do {
			try Render.validateMarkdownInput(URL(fileURLWithPath: path))
			Issue.record("expected a ValidationError for \(path)")
		} catch let error as ValidationError {
			#expect(error.message.contains("HTML input is not supported"))
			#expect(error.message.contains(".md/.markdown"))
		} catch {
			Issue.record("unexpected error \(error)")
		}
	}

	@Test("Markdown inputs are accepted", arguments: ["a.md", "a.markdown", "A.MD", "notes.txt", "README.mdx", "post.qmd", "file.rmd"])
	func acceptsMarkdown(path: String) throws {
		try Render.validateMarkdownInput(URL(fileURLWithPath: path))
	}
}

@Suite("render non-Markdown types")
struct RenderNonMarkdownTests {
	@Test("binary and document types are rejected", arguments: ["a.pdf", "a.docx", "a.png"])
	func rejects(path: String) {
		#expect(throws: ValidationError.self) { try Render.validateMarkdownInput(URL(fileURLWithPath: path)) }
	}
}

@Suite("render run rejects HTML input")
struct RenderRunTests {
	@Test("run() on an existing .html file throws a ValidationError")
	func runRejectsHTMLFile() async throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).html")
		try "<!DOCTYPE html><html><body>x</body></html>".write(to: url, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: url) }
		var command = try Render.parse([url.path, "-o", url.deletingPathExtension().appendingPathExtension("pdf").path])
		await #expect(throws: ValidationError.self) { try await command.run() }
	}
}

@Suite("render heading page breaks")
struct RenderHeadingBreakTests {
	@Test("the first block of the document is exempt from the heading break")
	func firstBlockExempt() {
		let html = markdownToHTML("# Buch\n\n# Kapitel 1\n\nText.\n\n# Kapitel 2\n\nText.",
		                          paper: .a4, landscape: false, pageBreakBefore: .h1)
		#expect(html.contains("h1 { page-break-before: always; break-before: page; }"))
		let exempt = "body > h1:first-child { page-break-before: auto; break-before: auto; }"
		let always = html.range(of: "h1 { page-break-before: always")
		let reset = html.range(of: exempt)
		#expect(reset != nil)
		if let always, let reset { #expect(always.lowerBound < reset.lowerBound) }
	}
}

@Suite("render footnotes page")
struct RenderFootnotePageTests {
	private let markdown = "Satz.[^a]\n\n[^a]: Note."

	@Test("page placement embeds the print-time paginator, section and end do not")
	func pageEmbedsPaginator() {
		let page = markdownToHTML(markdown, paper: .a4, landscape: false, footnotes: .page)
		#expect(page.contains("beforeprint"))
		#expect(page.contains(".fn-notes"))
		#expect(page.contains("id=\"fn-1\""))
		for placement in [FootnotePlacement.section, .end] {
			let html = markdownToHTML(markdown, paper: .a4, landscape: false, footnotes: placement)
			#expect(!html.contains("beforeprint"))
		}
	}
}
