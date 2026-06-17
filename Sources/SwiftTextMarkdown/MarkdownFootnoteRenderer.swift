import Foundation
import Markdown

/// Markdown -> HTML renderer that adds GitHub/Pandoc-style footnote support
/// on top of ``SwiftMarkdownHTMLRenderer``.
///
/// swift-markdown (and the cmark-gfm extensions it enables) doesn't parse the
/// `[^id]` / `[^id]: …` footnote syntax. To preserve that feature without
/// forking the upstream parser, this renderer:
///
/// 1. Line-scans the source for `[^id]: …` definition blocks (with optional
///    4-space-indented continuation lines) and removes them from the source.
/// 2. Parses the cleaned source into a swift-markdown `Document`.
/// 3. Walks the AST with a ``MarkupRewriter`` and replaces each `[^id]`
///    reference in `Text` nodes with a Private-Use-Area sentinel string.
///    `InlineCode` and `CodeBlock` are skipped automatically because their
///    content lives in a non-`Text` property the walker never descends into.
/// 4. Renders the rewritten document through ``SwiftMarkdownHTMLRenderer``.
/// 5. Expands the sentinels in the rendered HTML into `<sup><a …>[N]</a></sup>`
///    anchors and appends a definitions block at the end.
///
/// Only references whose identifier matches an extracted definition are
/// substituted — orphan references render as literal text. Numbers are
/// assigned in source-order of first appearance (matching most GFM-style
/// renderers).
///
/// The definition scanner and source-order numbering live in
/// ``MarkdownFootnoteParser`` so the Markdown → DOCX writer can reuse them to
/// emit native Word footnotes.
public enum MarkdownFootnoteRenderer {

	/// Converts Markdown to an HTML fragment, expanding `[^id]` footnote
	/// references and `[^id]: …` definition blocks.
	public static func convert(
		_ markdown: String, options: SwiftMarkdownHTMLRenderer.Options = []
	) -> String {
		let (cleaned, definitions) = extractFootnoteDefinitions(from: markdown)

		// Fast path: no definitions at all -> nothing to rewrite, render directly.
		if definitions.isEmpty {
			return SwiftMarkdownHTMLRenderer.convert(cleaned, options: options)
		}

		let state = FootnoteState(definitionIDs: definitions.map { $0.id })

		// Rewrite references in the main body.
		let bodyDocument = Document(parsing: cleaned, options: [])
		var bodyRewriter = FootnoteReferenceRewriter(state: state)
		let rewrittenBody = bodyRewriter.visit(bodyDocument) as? Document ?? bodyDocument
		let bodyHTML = SwiftMarkdownHTMLRenderer.convert(document: rewrittenBody, options: options)

		// Render each definition body, rewriting nested references too.
		// Rendering a definition can assign a number to a definition that was
		// only ever referenced from another definition's body — and that other
		// definition may appear earlier in the source. Re-scan until no pass
		// renders anything new so such chains resolve regardless of source order.
		var renderedDefinitions: [(number: Int, html: String)] = []
		var renderedIDs = Set<String>()
		var renderedNewDefinition = true
		while renderedNewDefinition {
			renderedNewDefinition = false
			for definition in definitions where !renderedIDs.contains(definition.id) {
				guard let number = state.number(forID: definition.id) else {
					// Definition not referenced (yet) — skip it.
					continue
				}
				let defDocument = Document(parsing: definition.body, options: [])
				var defRewriter = FootnoteReferenceRewriter(state: state)
				let rewrittenDef = defRewriter.visit(defDocument) as? Document ?? defDocument
				let defBodyHTML = SwiftMarkdownHTMLRenderer.convert(document: rewrittenDef, options: options)
				renderedDefinitions.append((number, defBodyHTML))
				renderedIDs.insert(definition.id)
				renderedNewDefinition = true
			}
		}

		// Two-pass sentinel expansion so nested refs inside definition bodies
		// also get the correct per-occurrence anchor id.
		let expandedBody = expandSentinels(in: bodyHTML, state: state)
		let definitionsHTML = renderDefinitionsBlock(renderedDefinitions, state: state)

		if definitionsHTML.isEmpty {
			return expandedBody
		}
		return expandedBody + "\n" + definitionsHTML
	}
}

// MARK: - Sentinel expansion

/// Replaces every sentinel in `html` with a `<sup><a …>[N]</a></sup>` anchor.
/// Per-occurrence anchor ids are assigned in document order (the order they
/// appear in the rendered HTML), which lets the definitions block link back to
/// the first occurrence cleanly.
private func expandSentinels(in html: String, state: FootnoteState) -> String {
	guard html.contains(footnoteSentinelOpen) else { return html }

	var result = ""
	result.reserveCapacity(html.count)

	var index = html.startIndex
	while index < html.endIndex {
		guard let openIndex = html[index...].firstIndex(of: footnoteSentinelOpen) else {
			result.append(contentsOf: html[index...])
			break
		}
		result.append(contentsOf: html[index..<openIndex])

		let payloadStart = html.index(after: openIndex)
		guard let closeIndex = html[payloadStart...].firstIndex(of: footnoteSentinelClose) else {
			// Malformed — emit the rest verbatim and stop.
			result.append(contentsOf: html[openIndex...])
			break
		}
		let payload = html[payloadStart..<closeIndex]
		let prefix = "fnref:"
		if payload.hasPrefix(prefix),
		   let number = Int(payload.dropFirst(prefix.count)) {
			let anchorID = state.nextReferenceAnchorID(forNumber: number)
			result += "<sup><a href=\"#fn-\(number)\" id=\"\(anchorID)\">[\(number)]</a></sup>"
		} else {
			// Unknown payload — pass through verbatim.
			result.append(contentsOf: html[openIndex...html.index(after: closeIndex)])
		}
		index = html.index(after: closeIndex)
	}

	return result
}

// MARK: - Definitions block

private func renderDefinitionsBlock(
	_ rendered: [(number: Int, html: String)],
	state: FootnoteState
) -> String {
	guard !rendered.isEmpty else { return "" }
	let sorted = rendered.sorted { $0.number < $1.number }

	var output = ""
	for (index, entry) in sorted.enumerated() {
		if index > 0 { output += "\n" }
		output += renderDefinition(number: entry.number, body: entry.html, state: state)
	}
	return output
}

private func renderDefinition(number: Int, body: String, state: FootnoteState) -> String {
	let expandedBody = expandSentinels(in: body, state: state)
	let bodyContent = expandedBody.trimmingCharacters(in: .whitespacesAndNewlines)

	// If swift-markdown produced a single paragraph for the body, inline it
	// next to the `[N]:` label so we don't introduce a blank line in print.
	if bodyContent.hasPrefix("<p>"), bodyContent.hasSuffix("</p>"),
	   let firstClose = bodyContent.range(of: "</p>"),
	   firstClose.upperBound == bodyContent.endIndex {
		let inner = bodyContent.dropFirst(3).dropLast(4)
		return "<div class=\"footnote-definition\" id=\"fn-\(number)\"><strong>[\(number)]:</strong> \(inner)</div>"
	}

	if bodyContent.isEmpty {
		return "<div class=\"footnote-definition\" id=\"fn-\(number)\"><strong>[\(number)]:</strong></div>"
	}

	return "<div class=\"footnote-definition\" id=\"fn-\(number)\"><p><strong>[\(number)]:</strong></p>\(bodyContent)</div>"
}
