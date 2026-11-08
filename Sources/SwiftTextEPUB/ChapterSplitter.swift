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
}

enum ChapterSplitter {

	/// Splits `document` into chapters at headings of exactly `chapterLevel`
	/// (1–6). Leading content becomes front matter. `titleFallback` names a
	/// chapter whose heading is empty (or the front matter, which is never
	/// listed but still needs an id).
	static func split(document: Document, chapterLevel: Int, titleFallback: String, footnotes: [MarkdownFootnoteParser.Definition] = []) -> [EpubChapter] {
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
			let body = renderBody(run.blocks, footnotes: footnotes)
			let title = chapterTitle(from: run.blocks, fallback: titleFallback)
			chapters.append(EpubChapter(id: id, title: title, bodyXHTML: body, isFrontmatter: isFrontmatter))
		}
		return chapters
	}

	/// A chapter's title is its split-level heading. Only when that heading is a
	/// bare label — a number with at most one word, like `1` or `Chapter 1` — are
	/// the leading consecutive headings joined with ": ", so a `## 1` followed by
	/// `### The Birthday…` reads as "1: The Birthday…" in the table of contents.
	/// A heading with real words (`## Teil 1: Wo Sie stehen`) stands alone. Both
	/// headings appear in the chapter body either way. Falls back to `fallback`
	/// when there is no leading heading (e.g. the front-matter section).
	private static func chapterTitle(from blocks: [BlockMarkup], fallback: String) -> String {
		let leadingHeadings = blocks.prefix { $0 is Heading }.compactMap { $0 as? Heading }
		let parts = leadingHeadings
			.map { swiftMarkdownPlainText(of: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		guard let first = parts.first else { return fallback }
		return isBareLabel(first) ? parts.joined(separator: ": ") : first
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
	private static func renderBody(_ blocks: [BlockMarkup], footnotes: [MarkdownFootnoteParser.Definition]) -> String {
		let subdocument = Document(blocks, inheritSourceRange: false)
		guard !footnotes.isEmpty else {
			return SwiftMarkdownHTMLRenderer.convert(document: subdocument, options: [.xhtml])
		}
		let state = EpubFootnoteState(definitions: footnotes)
		let body = state.render(subdocument, options: [.xhtml])
		let expanded = state.expandReferences(in: body)
		let section = state.renderFootnotesSection(options: [.xhtml])
		return section.isEmpty ? expanded : expanded + "\n" + section
	}
}
