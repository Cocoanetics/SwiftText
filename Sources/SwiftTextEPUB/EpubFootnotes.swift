//  EpubFootnotes.swift
//  SwiftTextEPUB
//
//  Markdown footnotes (`[^id]` references, `[^id]: text` definitions) as EPUB 3
//  noteref links plus `<aside epub:type="footnote">` blocks, gathered in a
//  `<section epub:type="footnotes">` after a separator rule, each note opening
//  with a numbered backlink to its reference. Each chapter file
//  gets its own numbering and carries the definitions it references, so reading
//  systems can show them as pop-up notes (which need the note in the same file).

import Foundation
import Markdown
import SwiftTextMarkdown

// Private Use Area sentinels, as in the HTML renderer: CommonMark-inert and
// untouched by HTML escaping, so they survive rendering and are expanded after.
private let sentinelOpen: Character = "\u{E000}"
private let sentinelClose: Character = "\u{E001}"

/// Footnote state for one chapter: numbering in order of first reference and
/// unique per-occurrence anchor ids.
final class EpubFootnoteState {
	let definitions: [MarkdownFootnoteParser.Definition]
	private let resolver: MarkdownFootnoteResolver
	private var emitted: [Int: Int] = [:]
	private let slugByID: [String: String]

	init(definitions: [MarkdownFootnoteParser.Definition]) {
		self.definitions = definitions
		self.resolver = MarkdownFootnoteResolver(definitionIDs: definitions.map(\.id))
		// Sanitizing can map different ids to one slug; suffix later ones so
		// every fragment id in the chapter stays unique.
		var used = Set<String>()
		var slugs: [String: String] = [:]
		for definition in definitions {
			let base = Self.slug(definition.id)
			var candidate = base
			var n = 1
			while !used.insert(candidate).inserted {
				n += 1
				candidate = "\(base)-\(n)"
			}
			slugs[definition.id] = candidate
		}
		self.slugByID = slugs
	}

	/// `text` with each matched reference replaced by a sentinel carrying its number.
	func markReferences(in text: String) -> String {
		resolver.resolve(text).map { segment in
			switch segment {
			case .text(let string): return string
			case .reference(let number): return "\(sentinelOpen)\(number)\(sentinelClose)"
			}
		}.joined()
	}

	private func id(forNumber number: Int) -> String? {
		definitions.first { resolver.number(forID: $0.id) == number }?.id
	}

	/// Replaces sentinels in rendered XHTML with noteref links.
	func expandReferences(in html: String) -> String {
		guard html.contains(sentinelOpen) else { return html }
		var result = ""
		var index = html.startIndex
		while index < html.endIndex {
			guard let open = html[index...].firstIndex(of: sentinelOpen),
			      let close = html[open...].firstIndex(of: sentinelClose) else {
				result.append(contentsOf: html[index...])
				break
			}
			result.append(contentsOf: html[index..<open])
			let payload = html[html.index(after: open)..<close]
			if let number = Int(payload), let id = id(forNumber: number) {
				let occurrence = (emitted[number] ?? 0) + 1
				emitted[number] = occurrence
				let slug = slugByID[id] ?? Self.slug(id)
				let anchor = occurrence == 1 ? "ref-\(slug)" : "ref-\(slug)-\(occurrence)"
				result += "<sup><a href=\"#fn-\(slug)\" id=\"\(anchor)\" class=\"noteref\" epub:type=\"noteref\" role=\"doc-noteref\">\(number)</a></sup>"
			}
			index = html.index(after: close)
		}
		return result
	}

	/// An XML-id-safe form of a footnote identifier.
	static func slug(_ id: String) -> String {
		String(id.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") ? $0 : "-" })
	}

	/// The footnotes section for every referenced definition, in number order, or
	/// `""` when none is referenced. Rendering a definition can reference further
	/// ones, so repeat until stable.
	func renderFootnotesSection(options: SwiftMarkdownHTMLRenderer.Options) -> String {
		var rendered: [(number: Int, html: String)] = []
		var done = Set<String>()
		var progress = true
		while progress {
			progress = false
			for definition in definitions where !done.contains(definition.id) {
				guard let number = resolver.number(forID: definition.id) else { continue }
				done.insert(definition.id)
				progress = true
				let body = renderMarkdown(definition.body, options: options)
				let content = expandReferences(in: body).trimmingCharacters(in: .whitespacesAndNewlines)
				let slug = slugByID[definition.id] ?? Self.slug(definition.id)
				rendered.append((number, "<aside id=\"fn-\(slug)\" class=\"footnote\" epub:type=\"footnote\" role=\"doc-footnote\">\(Self.withBacklink(content, number: number, slug: slug))</aside>"))
			}
		}
		guard !rendered.isEmpty else { return "" }
		let asides = rendered.sorted { $0.number < $1.number }.map(\.html).joined(separator: "\n")
		return "<section class=\"footnotes\" epub:type=\"footnotes\">\n<hr/>\n\(asides)\n</section>"
	}

	/// Puts the numbered backlink at the start of the note's first paragraph, or in a
	/// paragraph of its own when the note opens with another kind of block.
	private static func withBacklink(_ content: String, number: Int, slug: String) -> String {
		let link = "<a href=\"#ref-\(slug)\" class=\"footnote-backlink\" epub:type=\"backlink\" role=\"doc-backlink\">\(number)</a>"
		if content.hasPrefix("<p>") {
			return "<p>\(link) " + content.dropFirst(3)
		}
		return "<p class=\"footnote-label\">\(link)</p>" + content
	}

	func renderMarkdown(_ markdown: String, options: SwiftMarkdownHTMLRenderer.Options) -> String {
		let document = Document(parsing: markdown, options: [.disableSmartOpts])
		return render(document, options: options)
	}

	func render(_ document: Document, options: SwiftMarkdownHTMLRenderer.Options) -> String {
		var rewriter = EpubFootnoteRewriter(state: self)
		let rewritten = rewriter.visit(document) as? Document ?? document
		return SwiftMarkdownHTMLRenderer.convert(document: rewritten, options: options)
	}
}

private struct EpubFootnoteRewriter: MarkupRewriter {
	let state: EpubFootnoteState

	// Alt text is rendered into an attribute, so a reference there must stay literal.
	mutating func visitImage(_ image: Image) -> Markup? {
		image
	}

	mutating func visitText(_ text: Text) -> Markup? {
		guard text.string.contains("[^") else { return text }
		let marked = state.markReferences(in: text.string)
		return marked == text.string ? text : Text(marked)
	}
}
