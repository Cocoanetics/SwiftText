#if os(macOS)
import ArgumentParser
import Foundation
import PDFKit
import SwiftTextHTML
import Testing
@testable import SwiftTextCLI

@Suite("render PDF page furniture", .serialized)
@MainActor
struct RenderPageFurnitureTests {
	private func render(_ markdown: String, arguments: [String] = [], css: String? = nil, engine: String = "webkit") async throws -> PDFDocument {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let input = directory.appendingPathComponent("book.md")
		let output = directory.appendingPathComponent("book.pdf")
		try markdown.write(to: input, atomically: true, encoding: .utf8)
		var options = [input.path, "-o", output.path, "--engine", engine, "--title", "Ein Buch", "--page-break-before", "h1"] + arguments
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

	private func bodyHeadingTop(_ heading: String, on page: PDFPage, in document: PDFDocument) throws -> CGFloat {
		let pageTop = page.bounds(for: .mediaBox).maxY
		let selection = try #require(document.findString(heading, withOptions: []).first {
			$0.pages.contains(page) && $0.bounds(for: page).maxY < pageTop - 42
		})
		return selection.bounds(for: page).maxY
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

	@Test("the webkit engine leaves the title page bare", .timeLimit(.minutes(2)))
	func webkitTitlePageBare() async throws {
		let prose = "Langer Absatz mit vielen Wörtern für den Seitenumbruch und die Fortsetzung des Kapitels. "
		let markdown = (1...3).map { chapter in
			"# Kapitel \(chapter)\n\n" + (1...6).map { _ in String(repeating: prose, count: 8) }.joined(separator: "\n\n")
		}.joined(separator: "\n\n")
		let document = try await render(markdown, arguments: ["--running-heads", "--title-page", "--toc", "--author", "A. Autor"])
		try #require(document.pageCount > 3)
		let title = try #require(document.page(at: 0))
		#expect(text(on: title, from: 0, to: 0.08).isEmpty && text(on: title, from: 0.92, to: 1).isEmpty, "the title page carries no furniture")
		let contents = try #require(document.page(at: 1))
		#expect(text(on: contents, from: 0, to: 0.08) == "2", "the contents page keeps its number")
		#expect(text(on: contents, from: 0.92, to: 1).isEmpty, "no running head before the first chapter")
	}

	@Test("the webkit engine leaves every page of a multi-page title section bare", .timeLimit(.minutes(2)))
	func webkitLongTitleSectionBare() async throws {
		let authors = (1...40).flatMap { ["--author", "Autorin Nummer \($0)"] }
		let document = try await render("# Kapitel 1\n\nText.", arguments: ["--running-heads", "--title-page"] + authors)
		let first = try #require(document.findString("Kapitel 1", withOptions: []).first?.pages.first)
		let chapterIndex = document.index(for: first)
		try #require(chapterIndex > 1, "the fixture must spill the title section onto a second page")
		for index in 0..<chapterIndex {
			let page = try #require(document.page(at: index))
			#expect(text(on: page, from: 0, to: 0.08).isEmpty && text(on: page, from: 0.92, to: 1).isEmpty, "title page \(index + 1) carries furniture")
		}
		#expect(text(on: try #require(document.page(at: chapterIndex)), from: 0, to: 0.08) == String(chapterIndex + 1))
	}

	@Test("the swift engine draws numbers and running heads, and leaves the title page bare", .timeLimit(.minutes(2)))
	func swiftEngineFurniture() async throws {
		let prose = "Langer Absatz mit vielen Wörtern für den Seitenumbruch und die Fortsetzung des Kapitels. "
		let markdown = (1...3).map { chapter in
			"# Kapitel \(chapter)\n\n" + (1...6).map { _ in String(repeating: prose, count: 8) }.joined(separator: "\n\n")
		}.joined(separator: "\n\n")
		let document = try await render(markdown, arguments: ["--running-heads", "--title-page", "--toc", "--author", "A. Autor"], engine: "swift")
		try #require(document.pageCount > 5)
		var currentChapter = 0
		for index in 0..<document.pageCount {
			let page = try #require(document.page(at: index))
			let footer = text(on: page, from: 0, to: 0.08)
			let header = text(on: page, from: 0.92, to: 1)
			if index == 0 {
				#expect(footer.isEmpty && header.isEmpty, "the title page carries no furniture")
				continue
			}
			#expect(footer == String(index + 1), "page \(index + 1) has no footer number")
			#expect(header.contains("Ein Buch"), "page \(index + 1) has no book title")
			let body = text(on: page, from: 0.08, to: 0.92)
			for chapter in 1...3 where body.contains("Kapitel \(chapter) Langer") { currentChapter = chapter }
			if currentChapter > 0 { #expect(header.contains("Kapitel \(currentChapter)"), "page \(index + 1) has the wrong running chapter") }
		}
		// The contents' numbers agree with the numbers drawn on the pages.
		let contents = text(on: try #require(document.page(at: 1)), from: 0.08, to: 0.92)
		let chapterPage = try #require((0..<document.pageCount).first { index in
			index > 1 && text(on: document.page(at: index)!, from: 0.08, to: 0.92).contains("Kapitel 2 Langer")
		})
		#expect(contents.contains("Kapitel 2 \(chapterPage + 1)"))
	}

	private func half(on page: PDFPage, from bottom: CGFloat, to top: CGFloat, left: Bool) -> String {
		let bounds = page.bounds(for: .mediaBox)
		let band = CGRect(x: left ? bounds.minX : bounds.midX, y: bounds.minY + bottom * bounds.height, width: bounds.width / 2, height: (top - bottom) * bounds.height)
		return (page.selection(for: band)?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
	}

	@Test("mirrored heads and numbers from the first chapter give the classic book page furniture", .timeLimit(.minutes(3)), arguments: ["swift", "webkit"])
	func classicBookFurniture(engine: String) async throws {
		let prose = "Langer Absatz mit vielen Wörtern für den Seitenumbruch und die Fortsetzung des Kapitels. "
		let long = (1...14).map { _ in String(repeating: prose, count: 8) }.joined(separator: "\n\n")
		let document = try await render("# Eins\n\n\(long)\n\n# Zwei\n\nText.\n", arguments: ["--running-heads", "--mirrored-heads", "--number-from-chapter",
		                                                                                         "--title-page", "--toc", "--author", "A. Autor"], engine: engine)
		try #require(document.pageCount > 4, "the first chapter must continue over several pages")
		let first = try #require(document.page(at: 0))
		let contents = try #require(document.page(at: 1))
		for page in [first, contents] {
			#expect(text(on: page, from: 0, to: 0.08).isEmpty && text(on: page, from: 0.92, to: 1).isEmpty, "front matter carries no furniture")
		}
		var sawRightHead = false, sawLeftHead = false
		var zweiPage = 0
		for index in 2..<document.pageCount {
			let page = try #require(document.page(at: index))
			let isLeft = !index.isMultiple(of: 2)
			let body = text(on: page, from: 0.08, to: 0.92)
			let opensChapter = body.hasPrefix("Eins Langer") || body.hasPrefix("Zwei Text")
			if body.hasPrefix("Zwei") { zweiPage = index }
			let number = String(index - 1)
			#expect(half(on: page, from: 0, to: 0.08, left: isLeft) == number, "page \(index + 1) has its number \(number) on the outside edge")
			#expect(half(on: page, from: 0, to: 0.08, left: !isLeft).isEmpty, "page \(index + 1) has nothing on the inside edge")
			let outer = half(on: page, from: 0.95, to: 1, left: isLeft)
			let inner = half(on: page, from: 0.95, to: 1, left: !isLeft)
			#expect(inner.isEmpty, "page \(index + 1) has a head on the inside half")
			if opensChapter {
				#expect(outer.isEmpty, "page \(index + 1) opens a chapter and has no head")
			} else if isLeft {
				#expect(outer.contains("Ein Buch")); sawLeftHead = true
			} else {
				#expect(outer.contains("Eins")); sawRightHead = true
			}
		}
		#expect(sawLeftHead && sawRightHead)
		try #require(zweiPage > 2)
		let listed = text(on: contents, from: 0.08, to: 0.92)
		#expect(listed.contains("Eins 1"), "contents: \(listed)")
		#expect(listed.contains("Zwei \(zweiPage - 1)"), "contents lists the printed number: \(listed)")
	}

	@Test("numbering from the chapter works without running heads", .timeLimit(.minutes(3)), arguments: ["swift", "webkit"])
	func numberFromChapterWithoutHeads(engine: String) async throws {
		let document = try await render("# Eins\n\nText.\n\n# Zwei\n\nText.\n", arguments: ["--number-from-chapter", "--title-page", "--toc"], engine: engine)
		try #require(document.pageCount == 4)
		for index in 0..<2 { #expect(text(on: try #require(document.page(at: index)), from: 0, to: 0.08).isEmpty, "front matter page \(index + 1) is unnumbered") }
		#expect(text(on: try #require(document.page(at: 2)), from: 0, to: 0.08) == "1")
		#expect(text(on: try #require(document.page(at: 3)), from: 0, to: 0.08) == "2")
	}

	@Test("the swift engine keeps furniture inside the page and apart: zero margins, long heads", .timeLimit(.minutes(1)))
	func swiftEngineMarginsAndLongHeads() async throws {
		let long = String(repeating: "Ein sehr langer Kapitelname ", count: 6)
		let document = try await render("# \(long)\n\nText.", arguments: ["--running-heads", "--title", long], css: "@page { margin: 0; }", engine: "swift")
		let page = try #require(document.page(at: 0))
		#expect(text(on: page, from: 0, to: 0.08) == "1", "the footer must stay on the page with a zero margin")
		let header = text(on: page, from: 0.92, to: 1)
		#expect(header.contains("…"), "overlong heads are truncated, not overlapped: \(header)")
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
			#expect(try bodyHeadingTop(heading, on: page, in: document) <= page.bounds(for: .mediaBox).maxY - 80,
			        "larger authored margins must be retained")
		}
	}

	@Test("calculated page margins remain larger than the furniture band", .timeLimit(.minutes(1)))
	func calculatedMargin() async throws {
		let document = try await render("# Calculated Margin\n\nText.", arguments: ["--running-heads", "--no-page-numbers"],
		                                css: "@page { margin-top: calc(2cm + 10pt); }")
		let page = try #require(document.page(at: 0))
		#expect(try bodyHeadingTop("Calculated Margin", on: page, in: document) <= page.bounds(for: .mediaBox).maxY - 60,
		        "calc() must be resolved by WebKit instead of replaced with 48pt")
	}

	@Test("qualified and variable page margins remain scoped in the supplemental stylesheet", .timeLimit(.minutes(1)))
	func qualifiedMargins() async throws {
		let html = """
		<html><head><style>
		:root { --page-margin: 5cm; }
		@page { margin: 2cm; }
		@page :first { margin-top: 0; }
		@page :left { margin-top: 4cm; }
		@page named:right { margin-top: var(--page-margin); }
		</style></head><body><h1>Chapter</h1></body></html>
		"""
		let browser = WebKitBrowser(htmlString: html)
		await browser.waitForLoadCompletion()
		let preparation = try await browser.preparePageFurniture(paperSize: CGSize(width: 595.28, height: 841.89),
		                                                         footer: true, header: true, headingLevel: 1)
		let stylesheet = preparation.stylesheet
		#expect(stylesheet.contains("@page :first {margin-top:max(48pt, 0px) !important;"))
		#expect(stylesheet.contains("@page :left {margin-top:max(48pt, 4cm) !important;"))
		#expect(stylesheet.contains("@page named:right {margin-top:max(48pt, var(--page-margin)) !important;"))
		#expect(!stylesheet.contains("@page  {margin-top:max(48pt, 4cm)"), "qualified margins must not become document-wide")
	}
}
#endif
