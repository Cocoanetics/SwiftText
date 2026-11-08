import Foundation
import Testing
@testable import SwiftTextCLI

@Suite("render title page and contents")
struct FrontMatterTests {
	/// The issue's generated book: three chapters, two sections each.
	private static let book: String = {
		let lorem = "Lorem ipsum dolor sit amet, consetetur sadipscing elitr. "
		return (1...3).map { chapter in
			let sections = (1...2).map { "## Abschnitt \(chapter).\($0)\n\n\(lorem)" }.joined(separator: "\n")
			return "# Kapitel \(chapter)\n\n\(sections)"
		}.joined(separator: "\n")
	}()

	private func html(chapterLevel: Int = 1, depth: Int = 1, language: String = "en", titlePage: Bool = true, toc: Bool = true,
	                  pageNumbers: FrontMatter.PageNumbers = .none) -> String {
		var frontMatter = FrontMatter()
		if titlePage {
			frontMatter.titlePage = .init(title: "Ein <Buch>", subtitle: "Ein Untertitel", authors: ["A. Autor", "B. Autorin"])
		}
		if toc {
			frontMatter.contents = .init(chapterLevel: chapterLevel, depth: depth,
			                             heading: FrontMatter.contentsHeading(forLanguage: language), pageNumbers: pageNumbers)
		}
		return markdownToHTML(Self.book, paper: .a4, landscape: false, pageBreakBefore: .h1, language: language, frontMatter: frontMatter)
	}

	private func tocEntries(_ html: String) -> [(href: String, level: Int)] {
		let nav = String(html[html.range(of: "<nav class=\"toc\"")!.lowerBound...html.range(of: "</nav>")!.lowerBound])
		var entries: [(String, Int)] = []
		var remainder = nav[...]
		while let match = remainder.range(of: ##"toc-depth-(\d)"><a href="#([^"]*)""##, options: .regularExpression) {
			let token = remainder[match]
			let level = Int(token.dropFirst(10).prefix(1))! + 1
			entries.append((String(token.dropFirst(23).dropLast()), level))
			remainder = remainder[match.upperBound...]
		}
		return entries
	}

	@Test("title page precedes the chapters and the contents nest sections under chapters")
	func titlePageAndContents() throws {
		let output = html()
		let titlePage = try #require(output.range(of: "<section class=\"titlepage\">"))
		let nav = try #require(output.range(of: "<nav class=\"toc\""))
		let firstChapter = try #require(output.range(of: "<h1 id=\"kapitel-1\">"))
		#expect(titlePage.lowerBound < nav.lowerBound && nav.lowerBound < firstChapter.lowerBound)
		#expect(output.contains("<h1 class=\"title\">Ein &lt;Buch&gt;</h1>"))
		#expect(output.contains("<p class=\"subtitle\">Ein Untertitel</p>"))
		#expect(output.contains("<p class=\"author\">A. Autor</p>\n<p class=\"author\">B. Autorin</p>"))

		let entries = tocEntries(output)
		#expect(entries.filter { $0.level == 1 }.count == 3)
		#expect(entries.filter { $0.level == 2 }.count == 6)
		#expect(entries.map(\.level) == [1, 2, 2, 1, 2, 2, 1, 2, 2])
		for entry in entries {
			#expect(output.contains("id=\"\(entry.href)\""), "no heading has the id \(entry.href)")
		}
	}

	@Test("depth 0 lists chapters only; chapter level h2 lists sections")
	func depthAndLevel() {
		#expect(tocEntries(html(depth: 0)).count == 3)
		let sections = tocEntries(html(chapterLevel: 2, depth: 0))
		#expect(sections.count == 6)
		#expect(sections.allSatisfy { $0.href.hasPrefix("abschnitt") })
	}

	@Test("heading and lang follow --language")
	func language() {
		let german = html(language: "de")
		#expect(german.contains("<html lang=\"de\">"))
		#expect(german.contains("<p class=\"toc-title\">Inhalt</p>"))
		#expect(html().contains("Table of Contents"))
	}

	@Test("page numbers are placeholders, resolved numbers, or absent")
	func pageNumbers() {
		#expect(!html().contains("class=\"toc-page"))
		#expect(html(pageNumbers: .placeholder).contains("toc-pending\">000"))
		let resolved = html(pageNumbers: .resolved(["kapitel-1": 3]))
		#expect(resolved.contains("<td class=\"toc-page\">3</td>"))
		#expect(resolved.contains("<td class=\"toc-page\"></td>"), "a heading without a page shows no number")
	}

	@Test("without front matter the output has none")
	func off() {
		let plain = markdownToHTML(Self.book, paper: .a4, landscape: false)
		#expect(!plain.contains("titlepage\">") && !plain.contains("<nav"))
		#expect(plain.contains("<html lang=\"en\">"))
		#expect(!html(titlePage: false, toc: false).contains("<nav"))
	}

	@Test("the first chapter heading after the contents does not add a second break")
	func noBlankPageAfterContents() {
		// The title page and contents each end with a forced break, so a heading
		// right after them must not break again — that would leave a blank page.
		let withFront = html()
		#expect(withFront.contains("nav.toc { page-break-after: auto; break-after: auto; }"))
		#expect(!withFront.contains("nav.toc + h1"))
		// A preface between the contents and chapter 1 is not matched by the
		// sibling selectors, so chapter 1 still breaks before itself.
		let preface = markdownToHTML("Preface text.\n\n" + Self.book, paper: .a4, landscape: false, pageBreakBefore: .h1,
		                             frontMatter: FrontMatter(contents: .init(chapterLevel: 1, depth: 1, heading: "Contents", pageNumbers: .none)))
		#expect(preface.contains("</nav>\n<p>Preface text.</p>"))
		#expect(!preface.contains("nav.toc { page-break-after: auto"))
		let plain = markdownToHTML(Self.book, paper: .a4, landscape: false, pageBreakBefore: .h1)
		#expect(!plain.contains("nav.toc { page-break-after: auto"))
	}

	@Test("headings are read with their ids and plain text")
	func headingExtraction() {
		let found = FrontMatterHTML.headings(in: "<p>x</p><h2 id=\"a-b\">A &amp; <em>B</em></h2><h3>no id</h3>")
		#expect(found == [HeadingEntry(level: 2, id: "a-b", text: "A & B")])
		let image = FrontMatterHTML.headings(in: "<h1 id=\"c\"><img src=\"cover.png\" alt=\"Chapter &amp; One\"></h1>")
		#expect(image == [HeadingEntry(level: 1, id: "c", text: "Chapter & One")])
	}
}
