//  ChapterSplitter.swift
//  SwiftTextEPUB
//
//  Splits a parsed Markdown document into per-chapter XHTML fragments. A new
//  chapter file begins at every heading of the chosen level; any content before
//  the first such heading becomes a single front-matter section. Each chapter's
//  body is rendered through the Markdown renderer's XHTML mode so it is
//  well-formed XML suitable for an EPUB content document.

import Foundation
import Markdown
import SwiftTextMarkdown

/// One rendered chapter (or the front-matter section) of an EPUB.
struct EpubChapter {
	/// Stable id/basename, e.g. `ch001` — used for the file, manifest item, and
	/// the section anchor the nav/NCX point at.
	let id: String
	/// The heading text shown in the table of contents.
	let title: String
	/// The rendered XHTML body fragment (already escaped, void elements closed).
	let bodyXHTML: String
	/// Front matter is emitted in the spine but kept out of the reading-order
	/// table of contents (it has no chapter heading of its own).
	let isFrontmatter: Bool
	/// Sub-headings listed beneath the chapter in the table of contents, nested
	/// by level. Empty unless a TOC depth below the chapter level is requested.
	var subentries: [EpubTocEntry] = []
}

/// A sub-heading entry in the table of contents, pointing at the heading's id
/// inside its chapter file.
struct EpubTocEntry {
	let title: String
	/// The heading's `id` in the chapter XHTML, or `nil` when it has none (the
	/// entry then links to the chapter itself).
	let fragment: String?
	let level: Int
	var children: [EpubTocEntry] = []
}

enum ChapterSplitter {

	/// Splits `document` into chapters at headings of exactly `chapterLevel`
	/// (1–6). Leading content becomes front matter. `titleFallback` names a
	/// chapter whose heading is empty (or the front matter, which is never
	/// listed but still needs an id). `tocDepth` is how many heading levels below
	/// `chapterLevel` are collected as nested table-of-contents entries.
	static func split(document: Document, chapterLevel: Int, tocDepth: Int = 0, titleFallback: String,
	                  footnotes: [MarkdownFootnoteParser.Definition] = []) -> [EpubChapter] {
		let level = max(1, min(chapterLevel, 6))
		let blocks = document.children.compactMap { $0 as? BlockMarkup }

		// Partition top-level blocks into runs, each starting at a split heading.
		var runs: [(heading: Heading?, blocks: [BlockMarkup])] = []
		for block in blocks {
			if let heading = block as? Heading, heading.level == level {
				runs.append((heading, [block]))
			} else if runs.isEmpty {
				// Before the first split heading: begin the front-matter run.
				runs.append((nil, [block]))
			} else {
				runs[runs.count - 1].blocks.append(block)
			}
		}

		var chapters: [EpubChapter] = []
		var chapterNumber = 0
		for run in runs {
			let isFrontmatter = run.heading == nil
			chapterNumber += 1
			let id = String(format: "ch%03d", chapterNumber)
			let (body, headingIDs) = renderBody(run.blocks, footnotes: footnotes)
			let (title, titleHeadingCount) = chapterTitle(from: run.blocks, fallback: titleFallback)
			var chapter = EpubChapter(id: id, title: title, bodyXHTML: body, isFrontmatter: isFrontmatter)
			if !isFrontmatter && tocDepth > 0 {
				let headings = run.blocks.flatMap(headings(in:))
				// The renderer gives headings ids in document order, so the two lists
				// line up; if they ever don't, link entries to the chapter instead.
				let ids = headingIDs.count == headings.count ? headingIDs : Array(repeating: nil, count: headings.count)
				let listed = zip(headings, ids).dropFirst(titleHeadingCount).filter {
					$0.0.level > level && $0.0.level <= level + tocDepth
				}
				chapter.subentries = nest(listed.compactMap { heading, id in
					let text = SwiftMarkdownHTMLRenderer.splitHeadingID(
						swiftMarkdownPlainText(of: heading).trimmingCharacters(in: .whitespacesAndNewlines)).text
					return text.isEmpty ? nil : EpubTocEntry(title: text, fragment: id, level: heading.level)
				})
			}
			chapters.append(chapter)
		}
		return chapters
	}

	/// Every heading in `markup`, in document order.
	private static func headings(in markup: Markup) -> [Heading] {
		if let heading = markup as? Heading { return [heading] }
		return markup.children.flatMap(headings(in:))
	}

	/// Nests a flat, document-ordered list of entries by heading level: each entry
	/// becomes a child of the nearest preceding entry with a lower level.
	private static func nest(_ entries: [EpubTocEntry]) -> [EpubTocEntry] {
		var result: [EpubTocEntry] = []
		var index = 0
		while index < entries.count {
			var entry = entries[index]
			index += 1
			let start = index
			while index < entries.count && entries[index].level > entry.level { index += 1 }
			entry.children = nest(Array(entries[start..<index]))
			result.append(entry)
		}
		return result
	}

	/// A chapter's title is its split-level heading. Only when that heading is a
	/// bare label — a number with at most one word, like `1` or `Chapter 1` — are
	/// the leading consecutive headings joined with ": ", so a `## 1` followed by
	/// `### The Birthday…` reads as "1: The Birthday…" in the table of contents.
	/// A heading with real words (`## Teil 1: Wo Sie stehen`) stands alone. Both
	/// headings appear in the chapter body either way. Falls back to `fallback`
	/// when there is no leading heading (e.g. the front-matter section). Also
	/// returns how many leading headings the title consumed, so they aren't
	/// listed again as sub-entries.
	private static func chapterTitle(from blocks: [BlockMarkup], fallback: String) -> (title: String, headingCount: Int) {
		let leadingHeadings = blocks.prefix { $0 is Heading }.compactMap { $0 as? Heading }
		let parts = leadingHeadings
			.map { SwiftMarkdownHTMLRenderer.splitHeadingID(swiftMarkdownPlainText(of: $0).trimmingCharacters(in: .whitespacesAndNewlines)).text }
			.filter { !$0.isEmpty }
		guard let first = parts.first else { return (fallback, 0) }
		return isBareLabel(first) ? (parts.joined(separator: ": "), leadingHeadings.count) : (first, 1)
	}

	/// True for headings such as `1`, `IV` or `Chapter 1`: a label of at most one
	/// word that carries a digit, or a well-formed, upper-case Roman numeral.
	private static func isBareLabel(_ text: String) -> Bool {
		let words = text.split { !$0.isLetter && !$0.isNumber }
		let letterWords = words.filter { $0.contains(where: \.isLetter) }
		guard letterWords.count <= 1 else { return false }
		if text.contains(where: \.isNumber) { return true }
		guard let word = letterWords.first, words.count == 1 else { return false }
		let numeral = "^M{0,3}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})$"
		return !word.isEmpty && String(word).range(of: numeral, options: .regularExpression) != nil
	}

	/// Renders a run of top-level blocks to an XHTML fragment. Footnote
	/// references become noteref links and the definitions they use are
	/// appended as footnote asides, so each chapter file is self-contained.
	/// Headings get ids (the nav's link targets), returned in document order.
	private static func renderBody(_ blocks: [BlockMarkup], footnotes: [MarkdownFootnoteParser.Definition]) -> (body: String, headingIDs: [String?]) {
		let subdocument = Document(blocks, inheritSourceRange: false)
		guard !footnotes.isEmpty else {
			let body = SwiftMarkdownHTMLRenderer.convert(document: subdocument, options: [.xhtml, .headingIDs])
			return (body, headingIDs(in: body))
		}
		let state = EpubFootnoteState(definitions: footnotes)
		let body = state.render(subdocument, options: [.xhtml, .headingIDs])
		let expanded = state.expandReferences(in: body)
		let section = state.renderFootnotesSection(options: [.xhtml])
		return (section.isEmpty ? expanded : expanded + "\n" + section, headingIDs(in: body))
	}

	/// The `id` of every `<h1>`…`<h6>` start tag in `html`, in order (`nil` for a
	/// heading without one). Text and code are escaped, so only real tags match.
	private static func headingIDs(in html: String) -> [String?] {
		var ids: [String?] = []
		var remainder = html[...]
		while let range = remainder.range(of: #"<h[1-6]( id="[^"]*")?>"#, options: .regularExpression) {
			let tag = remainder[range]
			if let open = tag.range(of: "id=\"") {
				ids.append(String(tag[open.upperBound...].dropLast(2)))
			} else {
				ids.append(nil)
			}
			remainder = remainder[range.upperBound...]
		}
		return ids
	}
}
