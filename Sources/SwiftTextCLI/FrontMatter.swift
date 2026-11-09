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

/// Page numbers and running heads for the swift engine, as `@page` margin boxes.
enum SwiftPageFurniture {

	/// The stylesheet drawing the footer number and/or the header (book title left,
	/// current chapter right). The title page, when there is one, gets neither.
	static func css(pageNumbers: Bool, title: String?, hasTitlePage: Bool) -> String? {
		var boxes: [(area: String, content: String)] = []
		if pageNumbers { boxes.append(("bottom-center", "counter(page)")) }
		if let title {
			boxes.append(("top-left", cssString(title)))
			boxes.append(("top-right", "string(chapter)"))
		}
		guard !boxes.isEmpty else { return nil }
		let style = "font-size: 9pt; color: #555;"
		var css = "@page { " + boxes.map { "@\($0.area) { content: \($0.content); \(style) }" }.joined(separator: " ") + " }\n"
		if hasTitlePage {
			css += "@page :first { " + boxes.map { "@\($0.area) { content: none; }" }.joined(separator: " ") + " }\n"
		}
		return css
	}

	/// The chapter heading current on each page: the last heading of `level` that starts on or
	/// before it. `anchorPages` are zero-based; the result has one entry per page up to the last heading.
	static func chapterTitles(_ headings: [HeadingEntry], level: Int, anchorPages: [String: Int]) -> [String] {
		var startsOnPage: [Int: String] = [:]
		for heading in headings where heading.level == level {
			if let page = anchorPages[heading.id] { startsOnPage[page] = heading.text }
		}
		var current = ""
		return (0...max(startsOnPage.keys.max() ?? 0, anchorPages.values.max() ?? 0)).map { page in
			current = startsOnPage[page] ?? current
			return current
		}
	}

	private static func cssString(_ value: String) -> String {
		"\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
			.replacingOccurrences(of: "\n", with: " ") + "\""
	}
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

	/// The opening fence of a code block: its character and length.
	private static func fenceOpening(_ line: Substring) -> (mark: Character, length: Int)? {
		let trimmed = line.drop { $0 == " " }
		// Any indent: a fence can sit inside a list item.
		guard let mark = trimmed.first, mark == "`" || mark == "~" else { return nil }
		let length = trimmed.prefix { $0 == mark }.count
		guard length >= 3 else { return nil }
		// A backtick fence's info string cannot contain a backtick.
		if mark == "`", trimmed.dropFirst(length).contains("`") { return nil }
		return (mark, length)
	}

	/// Whether a line closes a fence: at least as long, same character, nothing else.
	private static func closesFence(_ line: Substring, _ fence: (mark: Character, length: Int)) -> Bool {
		guard let opening = fenceOpening(line), opening.mark == fence.mark, opening.length >= fence.length else { return false }
		return line.drop { $0 == " " }.dropFirst(opening.length).allSatisfy { $0 == " " || $0 == "\t" }
	}

	/// Whether a line is a contents marker: `<!-- toc -->` or `[TOC]` alone on it.
	private static func isContentsMarker(_ line: Substring) -> Bool {
		// Four spaces or a tab of indent make an indented code block, not a marker.
		guard !line.hasPrefix("    "), !line.hasPrefix("\t") else { return false }
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		if trimmed.caseInsensitiveCompare("[TOC]") == .orderedSame { return true }
		guard trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->"), trimmed.count >= 7 else { return false }
		return trimmed.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces).lowercased() == "toc"
	}

	/// Replaces the first contents marker line (outside code fences) with a placeholder
	/// paragraph and drops any later ones, so none of them reaches the output as text.
	/// The placeholder is a word the Markdown does not contain, so authored text cannot
	/// be mistaken for it; `placeholder` is the paragraph it converts to, nil if no marker.
	/// With `keepFirst` false (EPUB, which has no printed contents page) all are dropped.
	static func placeContentsMarker(in markdown: String, keepFirst: Bool = true) -> (markdown: String, placeholder: String?) {
		var found = false
		var fence: (mark: Character, length: Int)?
		var token = "SWIFTTEXTCONTENTSMARKER"
		while markdown.contains(token) { token += "X" }
		var lines: [String] = []
		// "\r\n" is a single Character in Swift, so normalise before splitting on "\n".
		let markdown = markdown.replacingOccurrences(of: "\r\n", with: "\n")
		for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
			if let open = fence {
				if closesFence(line, open) { fence = nil }
			} else if let open = fenceOpening(line) {
				fence = open
			} else if isContentsMarker(line) {
				if !found {
					found = true
					if keepFirst { lines.append(contentsOf: ["", token, ""]) }
				}
				continue
			}
			lines.append(String(line))
		}
		guard found else { return (markdown, nil) }
		return (lines.joined(separator: "\n"), keepFirst ? "<p>\(token)</p>" : nil)
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

	/// One table row per entry, indented by level: the text cell on the left and the page
	/// number in a right-aligned column. A table, not flexbox, so the swift engine (which
	/// has no flex layout) draws it too, and not a list, so no list marker can appear.
	private static func list(_ entries: ArraySlice<HeadingEntry>, pageNumbers: FrontMatter.PageNumbers) -> String {
		guard !entries.isEmpty else { return "" }
		let top = entries.map(\.level).min() ?? 1
		var html = "<table class=\"toc-list\">\n"
		for entry in entries {
			let indent = max(entry.level - top, 0)
			html += "<tr><td class=\"toc-text toc-depth-\(indent)\"><a href=\"#\(escape(entry.id, attribute: true))\">\(escape(entry.text))</a></td>"
			switch pageNumbers {
			case .none:
				html += "</tr>\n"
			case .placeholder:
				html += "<td class=\"toc-page toc-pending\">000</td></tr>\n"
			case .resolved(let pages):
				html += "<td class=\"toc-page\">\(pages[entry.id].map(String.init) ?? "")</td></tr>\n"
			}
		}
		return html + "</table>\n"
	}

	static let css = """
	.titlepage { padding-top: 6cm; text-align: center; page-break-after: always; break-after: page; }
	.titlepage h1.title { font-size: 2.6em; border: none; margin: 0 0 0.4em; page-break-before: auto; break-before: auto; }
	.titlepage .subtitle { font-size: 1.4em; color: #555; margin: 0 0 2.5em; }
	.titlepage .author { font-size: 1.15em; margin: 0.2em 0; }
	nav.toc { page-break-after: always; break-after: page; }
	nav.toc .toc-title { font-size: 2em; font-weight: 600; margin: 0 0 0.8em; }
	nav.toc table { width: 100%; border-collapse: collapse; border: none; margin: 0; }
	nav.toc td { border: none; padding: 0.15em 0; background: none; vertical-align: top; }
	nav.toc a { color: inherit; text-decoration: none; }
	nav.toc .toc-depth-1 { padding-left: 1.5em; }
	nav.toc .toc-depth-2 { padding-left: 3em; }
	nav.toc .toc-depth-3 { padding-left: 4.5em; }
	nav.toc .toc-depth-4 { padding-left: 6em; }
	nav.toc .toc-depth-5 { padding-left: 7.5em; }
	nav.toc .toc-page { width: 2.5em; text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }
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
