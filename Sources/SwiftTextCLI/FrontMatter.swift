//
//  FrontMatter.swift
//  SwiftText
//
//  The title page and contents page that `render` puts in front of HTML and PDF
//  output (`--title-page`, `--toc`), mirroring the EPUB's title page and nav.
//

import Foundation
import SwiftTextEPUB

/// What `markdownToHTML` emits ahead of the body.
struct FrontMatter {
	struct TitlePage {
		var title: String
		var subtitle: String?
		var authors: [String]
	}

	/// How the contents page shows page numbers.
	enum PageNumbers {
		/// No numbers (HTML output).
		case none
		/// Invisible fixed-width boxes, so a first PDF pass paginates like the last.
		case placeholder
		/// The physical page (1-based) of each heading id; a heading without one shows no number.
		case resolved([String: Int])
	}

	struct Contents {
		var chapterLevel: Int
		var depth: Int
		var heading: String
		var pageNumbers: PageNumbers
	}

	var titlePage: TitlePage?
	var contents: Contents?

	/// The contents heading for a BCP-47 language tag, as in the EPUB nav.
	static func contentsHeading(forLanguage language: String) -> String {
		EpubNavLabels.labels(forLanguage: language).tableOfContents
	}
}

/// One heading of the rendered body.
struct HeadingEntry: Equatable {
	var level: Int
	var id: String
	var text: String
}

enum FrontMatterHTML {

	/// Every `<h1>`…`<h6>` that carries an `id`, in document order, with its plain text.
	static func headings(in html: String) -> [HeadingEntry] {
		var result: [HeadingEntry] = []
		var remainder = html[...]
		while let range = remainder.range(of: #"<h([1-6])\s[^>]*?id="([^"]*)"[^>]*>(.*?)</h\1>"#, options: .regularExpression) {
			let match = String(remainder[range])
			remainder = remainder[range.upperBound...]
			guard let level = match.dropFirst(2).first.flatMap({ Int(String($0)) }),
			      let idRange = match.range(of: #"id="([^"]*)""#, options: .regularExpression),
			      let open = match.firstIndex(of: ">"), let close = match.range(of: "</h", options: .backwards) else { continue }
			let id = String(match[idRange].dropFirst(4).dropLast())
			let inner = String(match[match.index(after: open)..<close.lowerBound])
			// An image contributes its alt text, which is escaped inside the attribute.
			let withAlt = inner.replacingOccurrences(of: ##"<img\b[^>]*?\balt="([^"]*)"[^>]*>"##, with: "$1", options: .regularExpression)
			let text = unescape(withAlt.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
				.trimmingCharacters(in: .whitespacesAndNewlines)
			if !id.isEmpty && !text.isEmpty { result.append(HeadingEntry(level: level, id: id, text: text)) }
		}
		return result
	}

	/// The headings the contents lists: those of `chapterLevel` and up to `depth`
	/// levels below them, starting at the first chapter heading (like the EPUB nav).
	static func contentsEntries(_ headings: [HeadingEntry], chapterLevel: Int, depth: Int) -> [HeadingEntry] {
		var started = false
		return headings.filter { heading in
			if heading.level == chapterLevel { started = true }
			return started && heading.level >= chapterLevel && heading.level <= chapterLevel + depth
		}
	}

	static func titlePage(_ page: FrontMatter.TitlePage) -> String {
		var html = "<section class=\"titlepage\">\n<h1 class=\"title\">\(escape(page.title))</h1>\n"
		if let subtitle = page.subtitle, !subtitle.isEmpty {
			html += "<p class=\"subtitle\">\(escape(subtitle))</p>\n"
		}
		for author in page.authors where !author.isEmpty {
			html += "<p class=\"author\">\(escape(author))</p>\n"
		}
		return html + "</section>"
	}

	static func contents(_ contents: FrontMatter.Contents, headings: [HeadingEntry]) -> String {
		let entries = contentsEntries(headings, chapterLevel: contents.chapterLevel, depth: contents.depth)
		var html = "<nav class=\"toc\" role=\"doc-toc\">\n<p class=\"toc-title\">\(escape(contents.heading))</p>\n"
		html += list(entries[...], pageNumbers: contents.pageNumbers)
		return html + "</nav>"
	}

	/// Nests a flat, document-ordered run of entries by level: each entry holds the
	/// following entries of a deeper level.
	private static func list(_ entries: ArraySlice<HeadingEntry>, pageNumbers: FrontMatter.PageNumbers) -> String {
		guard !entries.isEmpty else { return "" }
		var html = "<ol>\n"
		var index = entries.startIndex
		while index < entries.endIndex {
			let entry = entries[index]
			index += 1
			let start = index
			while index < entries.endIndex && entries[index].level > entry.level { index += 1 }
			html += "<li><a href=\"#\(escape(entry.id, attribute: true))\"><span class=\"toc-text\">\(escape(entry.text))</span>"
			switch pageNumbers {
			case .none:
				break
			case .placeholder:
				html += "<span class=\"toc-fill\"></span><span class=\"toc-page toc-pending\">000</span>"
			case .resolved(let pages):
				html += "<span class=\"toc-fill\"></span><span class=\"toc-page\">\(pages[entry.id].map(String.init) ?? "")</span>"
			}
			html += "</a>\n" + list(entries[start..<index], pageNumbers: pageNumbers) + "</li>\n"
		}
		return html + "</ol>\n"
	}

	static let css = """
	.titlepage { padding-top: 6cm; text-align: center; page-break-after: always; break-after: page; }
	.titlepage h1.title { font-size: 2.6em; border: none; margin: 0 0 0.4em; page-break-before: auto; break-before: auto; }
	.titlepage .subtitle { font-size: 1.4em; color: #555; margin: 0 0 2.5em; }
	.titlepage .author { font-size: 1.15em; margin: 0.2em 0; }
	nav.toc { page-break-after: always; break-after: page; }
	nav.toc .toc-title { font-size: 2em; font-weight: 600; margin: 0 0 0.8em; }
	nav.toc ol { list-style: none; margin: 0; padding: 0; }
	nav.toc ol ol { padding-left: 1.5em; }
	nav.toc li { margin: 0.25em 0; page-break-inside: auto; break-inside: auto; }
	nav.toc a { display: flex; align-items: baseline; color: inherit; text-decoration: none; }
	nav.toc .toc-text { flex: 0 1 auto; }
	nav.toc .toc-fill { flex: 1 1 1em; min-width: 1em; margin: 0 0.4em; border-bottom: 1px dotted #888; }
	nav.toc .toc-page { flex: none; min-width: 2.5em; text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }
	nav.toc .toc-pending { visibility: hidden; }
	"""

	private static func escape(_ value: String, attribute: Bool = false) -> String {
		escapeHTMLMetadata(value, attribute: attribute)
	}

	private static func unescape(_ value: String) -> String {
		value.replacingOccurrences(of: "&lt;", with: "<")
			.replacingOccurrences(of: "&gt;", with: ">")
			.replacingOccurrences(of: "&quot;", with: "\"")
			.replacingOccurrences(of: "&#39;", with: "'")
			.replacingOccurrences(of: "&amp;", with: "&")
	}
}
