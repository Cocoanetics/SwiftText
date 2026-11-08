#if os(macOS)
import ArgumentParser
import Foundation
import PDFKit
import Testing
@testable import SwiftTextCLI

@Suite("render PDF page furniture", .serialized)
@MainActor
struct RenderPageFurnitureTests {
	private func render(_ markdown: String, arguments: [String] = [], css: String? = nil) async throws -> PDFDocument {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let input = directory.appendingPathComponent("book.md")
		let output = directory.appendingPathComponent("book.pdf")
		try markdown.write(to: input, atomically: true, encoding: .utf8)
		var options = [input.path, "-o", output.path, "--engine", "webkit", "--title", "Ein Buch", "--page-break-before", "h1"] + arguments
		if let css {
			let stylesheet = directory.appendingPathComponent("furniture.css")
			try css.write(to: stylesheet, atomically: true, encoding: .utf8)
			options += ["--css", stylesheet.path]
		}
		let command = try Render.parse(options)
		try await command.run()
		return try #require(PDFDocument(data: Data(contentsOf: output)))
	}

	private func text(on page: PDFPage, from bottom: CGFloat, to top: CGFloat) -> String {
		let bounds = page.bounds(for: .mediaBox)
		let band = CGRect(x: bounds.minX, y: bounds.minY + bottom * bounds.height, width: bounds.width, height: (top - bottom) * bounds.height)
		return (page.selection(for: band)?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
	}

	@Test("numbers and current chapter occupy the margin bands on every page", .timeLimit(.minutes(2)), arguments: ["section", "page"])
	func chapterFurniture(footnotes: String) async throws {
		let prose = "Langer Absatz mit vielen Wörtern für den Seitenumbruch und die Fortsetzung des Kapitels. "
		let markdown = (1...3).map { chapter in
			let sections = (1...2).map { section in
				let paragraphs = (1...6).map { paragraph in
					"\(String(repeating: "chapter-marker-\(chapter) \(prose)", count: 12))[^n\(chapter)-\(section)-\(paragraph)]"
				}.joined(separator: "\n\n")
				let notes = (1...6).map { "[^n\(chapter)-\(section)-\($0)]: Fußnote zum Absatz \($0)." }.joined(separator: "\n\n")
				return "## Abschnitt \(section)\n\n\(paragraphs)\n\n\(notes)"
			}.joined(separator: "\n\n")
			return "# Kapitel \(chapter)\n\n\(sections)"
		}.joined(separator: "\n\n")
		let document = try await render(markdown, arguments: ["--running-heads", "--footnotes", footnotes],
		                                css: "@page { @bottom-center { content: counter(page); } @top-center { content: 'Ein Buch'; } }")
		try #require(document.pageCount > 3, "the fixture must exercise chapter continuation pages")
		#expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Ein Buch")
		var currentChapter = 1
		for index in 0..<document.pageCount {
			let page = try #require(document.page(at: index))
			let body = text(on: page, from: 0.08, to: 0.92)
			for chapter in 1...3 where body.contains("Kapitel \(chapter)") { currentChapter = chapter }
			let header = text(on: page, from: 0.92, to: 1)
			#expect(header.contains("Ein Buch"), "page \(index + 1) has no book title in its top band")
			#expect(header.contains("Kapitel \(currentChapter)"), "page \(index + 1) has the wrong running chapter")
			let footer = text(on: page, from: 0, to: 0.08)
			#expect(footer.split(separator: " ").contains(Substring(String(index + 1))), "page \(index + 1) has no footer number")
			#expect(text(on: page, from: 0, to: 42 / page.bounds(for: .mediaBox).height) == String(index + 1), "the footer number must be clear of body text")
			#expect(!body.isEmpty, "page \(index + 1) must retain its body text")
		}
	}

	@Test("numbers default on, may be disabled, and running heads are opt in", .timeLimit(.minutes(1)))
	func defaultsAndOptOut() async throws {
		let numbered = try await render("# Kapitel 1\n\nText.")
		let first = try #require(numbered.page(at: 0))
		#expect(text(on: first, from: 0, to: 0.08) == "1")
		#expect(text(on: first, from: 0.92, to: 1).isEmpty)
		let plain = try await render("# Kapitel 1\n\nText.", arguments: ["--no-page-numbers"])
		#expect(text(on: try #require(plain.page(at: 0)), from: 0, to: 0.08).isEmpty)
	}

	@Test("small authored margins leave furniture clear of page footnotes and preserve links", .timeLimit(.minutes(1)))
	func smallMarginsAndLinks() async throws {
		let markdown = """
		# Kapitel 1

		[External](https://example.com) and [next chapter](#kapitel-2). Text.[^a]

		[^a]: Eine Fußnote am Seitenende.

		# Kapitel 2

		Second chapter.
		"""
		let document = try await render(markdown, arguments: ["--page-numbers", "--running-heads", "--footnotes", "page", "--paper", "letter", "--landscape"],
		                                css: "@page { margin: 0; }")
		#expect(document.pageCount == 2)
		let first = try #require(document.page(at: 0))
		#expect(text(on: first, from: 0, to: 0.08) == "1")
		#expect(text(on: first, from: 0.08, to: 0.92).contains("Eine Fußnote"))
		#expect(text(on: first, from: 0.92, to: 1).contains("Ein Buch"))
		#expect(first.annotations.contains { $0.url?.host == "example.com" })
		let internalLink = try #require(first.annotations.compactMap { $0.action as? PDFActionGoTo }.first)
		#expect(internalLink.destination.page === document.page(at: 1))
	}

	@Test("help documents both furniture controls")
	func help() throws {
		let help = Render.helpMessage()
		#expect(help.contains("--page-numbers/--no-page-numbers"))
		#expect(help.contains("--running-heads"))
		#expect(try Render.parse([]).pageNumbers)
		#expect(try !Render.parse(["--no-page-numbers"]).pageNumbers)
	}

	@Test("running heads follow the selected chapter level without numbers", .timeLimit(.minutes(1)))
	func chapterLevelAndHeaderOnly() async throws {
		let document = try await render("## Erster Teil\n\nText.\n\n## Zweiter Teil\n\nMore text.",
		                                arguments: ["--page-break-before", "h2", "--running-heads", "--no-page-numbers"],
		                                css: "@page { margin: 3cm; }")
		try #require(document.pageCount == 2)
		for (index, heading) in ["Erster Teil", "Zweiter Teil"].enumerated() {
			let page = try #require(document.page(at: index))
			let header = text(on: page, from: 0.92, to: 1)
			#expect(header.contains("Ein Buch") && header.contains(heading))
			#expect(text(on: page, from: 0, to: 0.08).isEmpty)
			let bodyHeading = try #require(document.findString(heading, withOptions: []).first {
				$0.pages.contains(page) && $0.bounds(for: page).maxY < page.bounds(for: .mediaBox).maxY - 42
			})
			#expect(bodyHeading.bounds(for: page).maxY <= page.bounds(for: .mediaBox).maxY - 80, "larger authored margins must be retained")
		}
	}
}
#endif
