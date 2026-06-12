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
public enum MarkdownFootnoteRenderer {

	/// Converts Markdown to an HTML fragment, expanding `[^id]` footnote
	/// references and `[^id]: …` definition blocks.
	public static func convert(
		_ markdown: String, options: SwiftMarkdownHTMLRenderer.Options = []
	) -> String {
		let (cleaned, definitions) = extractDefinitions(from: markdown)

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

// MARK: - Definition extraction

private struct FootnoteDefinition {
	let id: String
	let body: String
}

/// Scans source markdown for `[^id]: …` definition blocks. Returns the source
/// with those blocks removed, plus the captured definitions in source order.
///
/// A definition spans the marker line plus any subsequent lines that are either
/// blank or indented by at least 4 spaces / one tab (the standard GFM rule).
/// Indentation is stripped from continuation lines so the captured body is plain
/// Markdown.
private func extractDefinitions(from source: String) -> (cleaned: String, definitions: [FootnoteDefinition]) {
	let normalized = source
		.replacingOccurrences(of: "\r\n", with: "\n")
		.replacingOccurrences(of: "\r", with: "\n")
	let lines = normalized.components(separatedBy: "\n")

	var keptLines: [String] = []
	keptLines.reserveCapacity(lines.count)

	var definitions: [FootnoteDefinition] = []
	var seenIDs = Set<String>()

	var i = 0
	while i < lines.count {
		let line = lines[i]

		guard let start = parseDefinitionStart(line) else {
			keptLines.append(line)
			i += 1
			continue
		}

		// Collect body lines: the inline content after `]:`, plus any
		// indented/blank continuation lines.
		var bodyLines: [String] = []
		if !start.firstLineContent.isEmpty {
			bodyLines.append(start.firstLineContent)
		}

		var j = i + 1
		while j < lines.count {
			let next = lines[j]
			if next.trimmingCharacters(in: .whitespaces).isEmpty {
				// Look ahead: if the next non-blank line is also indented, the
				// blank line is part of the definition (paragraph break inside);
				// otherwise it terminates the definition.
				var lookahead = j + 1
				while lookahead < lines.count && lines[lookahead].trimmingCharacters(in: .whitespaces).isEmpty {
					lookahead += 1
				}
				if lookahead < lines.count, stripContinuationIndent(lines[lookahead]) != nil {
					bodyLines.append("")
					j += 1
					continue
				}
				break
			}
			if let stripped = stripContinuationIndent(next) {
				bodyLines.append(stripped)
				j += 1
				continue
			}
			break
		}

		// Skip duplicate definitions — first wins.
		if !seenIDs.contains(start.id) {
			definitions.append(FootnoteDefinition(id: start.id, body: bodyLines.joined(separator: "\n")))
			seenIDs.insert(start.id)
		}

		i = j
	}

	return (keptLines.joined(separator: "\n"), definitions)
}

private func parseDefinitionStart(_ line: String) -> (id: String, firstLineContent: String)? {
	guard line.hasPrefix("[^"),
	      let closingBracket = line.firstIndex(of: "]") else { return nil }
	let identifierStart = line.index(line.startIndex, offsetBy: 2)
	guard identifierStart < closingBracket else { return nil }
	let colonIndex = line.index(after: closingBracket)
	guard colonIndex < line.endIndex, line[colonIndex] == ":" else { return nil }

	let id = String(line[identifierStart..<closingBracket]).trimmingCharacters(in: .whitespaces)
	guard !id.isEmpty else { return nil }

	let contentStart = line.index(after: colonIndex)
	let content = contentStart < line.endIndex
		? String(line[contentStart...]).trimmingCharacters(in: .whitespaces)
		: ""
	return (id, content)
}

private func stripContinuationIndent(_ line: String) -> String? {
	if line.hasPrefix("\t") {
		return String(line.dropFirst())
	}
	if line.hasPrefix("    ") {
		return String(line.dropFirst(4))
	}
	return nil
}

// MARK: - Sentinels

// Private Use Area characters — CommonMark-inert, not touched by the renderer's
// HTML escape (which only rewrites `& < > "`), and vanishingly unlikely to
// appear in user content.
private let sentinelOpen: Character = "\u{E000}"
private let sentinelClose: Character = "\u{E001}"

private func referenceSentinel(number: Int) -> String {
	"\(sentinelOpen)fnref:\(number)\(sentinelClose)"
}

// MARK: - State

private final class FootnoteState {
	private let validIDs: Set<String>
	private var numberByID: [String: Int] = [:]
	private var nextNumber = 1
	private var totalReferenceCountByNumber: [Int: Int] = [:]
	private var emittedReferenceCountByNumber: [Int: Int] = [:]

	init(definitionIDs: [String]) {
		self.validIDs = Set(definitionIDs)
	}

	/// Assigns and returns the number for `id` on first reference. Returns
	/// `nil` if no matching definition was extracted — the rewriter then leaves
	/// the `[^id]` substring as literal text.
	func recordReference(forID id: String) -> Int? {
		guard validIDs.contains(id) else { return nil }
		let number: Int
		if let existing = numberByID[id] {
			number = existing
		} else {
			number = nextNumber
			numberByID[id] = number
			nextNumber += 1
		}
		totalReferenceCountByNumber[number, default: 0] += 1
		return number
	}

	/// Looks up an already-assigned number without recording a new reference.
	/// Used after rewriting to fetch numbers for the definitions block.
	func number(forID id: String) -> Int? {
		numberByID[id]
	}

	/// Returns the next per-occurrence anchor id for a reference. The first
	/// reference to footnote `N` gets `ref-N`; subsequent references get
	/// `ref-N-2`, `ref-N-3`, … so each anchor in the HTML is unique.
	func nextReferenceAnchorID(forNumber number: Int) -> String {
		let occurrence = (emittedReferenceCountByNumber[number] ?? 0) + 1
		emittedReferenceCountByNumber[number] = occurrence
		return occurrence == 1 ? "ref-\(number)" : "ref-\(number)-\(occurrence)"
	}
}

// MARK: - AST rewriter

private struct FootnoteReferenceRewriter: MarkupRewriter {
	let state: FootnoteState

	mutating func visitText(_ text: Text) -> Markup? {
		let original = text.string
		guard original.contains("[^") else { return text }
		let rewritten = replaceReferences(in: original)
		guard rewritten != original else { return text }
		return Text(rewritten)
	}

	private func replaceReferences(in input: String) -> String {
		// We scan manually rather than with NSRegularExpression so we can keep
		// the bounds rules simple: `[^` opens, the next `]` closes, the id is
		// non-empty and contains no whitespace or `]`. This matches the
		// hand-rolled parser's behavior closely enough for parity.
		var result = ""
		result.reserveCapacity(input.count)

		var index = input.startIndex
		while index < input.endIndex {
			guard let openRange = input.range(of: "[^", range: index..<input.endIndex) else {
				result.append(contentsOf: input[index...])
				break
			}
			result.append(contentsOf: input[index..<openRange.lowerBound])

			let idStart = openRange.upperBound
			guard let closeIndex = input[idStart...].firstIndex(of: "]") else {
				result.append(contentsOf: input[openRange.lowerBound...])
				break
			}
			let id = String(input[idStart..<closeIndex])
			let consumedEnd = input.index(after: closeIndex)

			let isValidShape = !id.isEmpty && !id.contains(where: { $0.isWhitespace })
			if isValidShape, let number = state.recordReference(forID: id) {
				result.append(referenceSentinel(number: number))
			} else {
				// No matching definition (or malformed id) — leave literal text.
				result.append(contentsOf: input[openRange.lowerBound..<consumedEnd])
			}
			index = consumedEnd
		}

		return result
	}
}

// MARK: - Sentinel expansion

/// Replaces every sentinel in `html` with a `<sup><a …>[N]</a></sup>` anchor.
/// Per-occurrence anchor ids are assigned in document order (the order they
/// appear in the rendered HTML), which lets the definitions block link back to
/// the first occurrence cleanly.
private func expandSentinels(in html: String, state: FootnoteState) -> String {
	guard html.contains(sentinelOpen) else { return html }

	var result = ""
	result.reserveCapacity(html.count)

	var index = html.startIndex
	while index < html.endIndex {
		guard let openIndex = html[index...].firstIndex(of: sentinelOpen) else {
			result.append(contentsOf: html[index...])
			break
		}
		result.append(contentsOf: html[index..<openIndex])

		let payloadStart = html.index(after: openIndex)
		guard let closeIndex = html[payloadStart...].firstIndex(of: sentinelClose) else {
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
