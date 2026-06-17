import Foundation
import Markdown

/// Format-agnostic core for the `[^id]` / `[^id]: …` footnote extension that
/// swift-markdown doesn't parse natively.
///
/// Two renderers build on this:
/// - ``MarkdownFootnoteRenderer`` (Markdown → HTML), which rewrites references
///   into sentinel strings and expands them after HTML rendering.
/// - The Markdown → DOCX writer, which walks the AST and splits each `Text`
///   node into ``MarkdownFootnoteParser/Segment`` values to emit native Word
///   `w:footnoteReference` runs.
///
/// Both share the same definition scanner and source-order numbering so the two
/// outputs stay consistent.
public enum MarkdownFootnoteParser {

	/// A `[^id]: …` definition: its identifier and its body as plain Markdown
	/// (continuation indentation already stripped).
	public struct Definition: Sendable, Equatable {
		public let id: String
		public let body: String

		public init(id: String, body: String) {
			self.id = id
			self.body = body
		}
	}

	/// One piece of a `Text` node after footnote-reference resolution: either a
	/// run of literal text or a footnote reference carrying its assigned number.
	public enum Segment: Sendable, Equatable {
		case text(String)
		case reference(Int)
	}

	/// Scans `source` for `[^id]: …` definition blocks. Returns the source with
	/// those blocks removed, plus the captured definitions in source order.
	public static func extractDefinitions(
		from source: String
	) -> (cleaned: String, definitions: [Definition]) {
		let result = extractFootnoteDefinitions(from: source)
		return (result.cleaned, result.definitions.map { Definition(id: $0.id, body: $0.body) })
	}
}

/// Stateful, source-order resolver for footnote references. Feed it the ids of
/// the extracted definitions, then call ``resolve(_:)`` on each `Text` node's
/// string in document order — numbers are assigned on first reference, matching
/// the HTML renderer's numbering.
///
/// References whose id has no matching definition (or whose shape is malformed)
/// are left as literal text, so `InlineCode`/`CodeBlock` content is preserved
/// automatically: the AST walker never feeds their strings here.
public final class MarkdownFootnoteResolver {
	private let state: FootnoteState

	public init(definitionIDs: [String]) {
		self.state = FootnoteState(definitionIDs: definitionIDs)
	}

	/// Splits `text` into literal-text and footnote-reference segments,
	/// recording each matched reference in source order.
	public func resolve(_ text: String) -> [MarkdownFootnoteParser.Segment] {
		scanFootnoteReferences(in: text, record: state.recordReference).map { event in
			switch event {
			case .literal(let string): return .text(string)
			case .reference(let number): return .reference(number)
			}
		}
	}

	/// The number assigned to `id`, or `nil` if it was never referenced.
	public func number(forID id: String) -> Int? {
		state.number(forID: id)
	}
}

// MARK: - Definition extraction

struct FootnoteDefinition {
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
func extractFootnoteDefinitions(
	from source: String
) -> (cleaned: String, definitions: [FootnoteDefinition]) {
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

// MARK: - Reference scanning

/// One token produced while scanning a `Text` node for `[^id]` references.
enum FootnoteScanEvent {
	case literal(String)
	case reference(Int)
}

/// Scans `input` for `[^id]` references, asking `record` to assign a number to
/// each well-formed id. A reference is replaced by a `.reference` event only
/// when `record` returns a number (i.e. the id has a matching definition);
/// otherwise the original `[^id]` text is preserved as literal output.
///
/// Both the HTML rewriter (sentinel strings) and the DOCX resolver (segments)
/// build their output from these events so the scan rules stay in one place.
func scanFootnoteReferences(in input: String, record: (String) -> Int?) -> [FootnoteScanEvent] {
	guard input.contains("[^") else { return [.literal(input)] }

	var events: [FootnoteScanEvent] = []
	var pending = ""

	var index = input.startIndex
	while index < input.endIndex {
		guard let openRange = input.range(of: "[^", range: index..<input.endIndex) else {
			pending += input[index...]
			break
		}
		pending += input[index..<openRange.lowerBound]

		let idStart = openRange.upperBound
		guard let closeIndex = input[idStart...].firstIndex(of: "]") else {
			pending += input[openRange.lowerBound...]
			break
		}
		let id = String(input[idStart..<closeIndex])
		let consumedEnd = input.index(after: closeIndex)

		let isValidShape = !id.isEmpty && !id.contains(where: { $0.isWhitespace })
		if isValidShape, let number = record(id) {
			if !pending.isEmpty {
				events.append(.literal(pending))
				pending = ""
			}
			events.append(.reference(number))
		} else {
			// No matching definition (or malformed id) — leave literal text.
			pending += input[openRange.lowerBound..<consumedEnd]
		}
		index = consumedEnd
	}

	if !pending.isEmpty {
		events.append(.literal(pending))
	}
	return events
}

// MARK: - Sentinels

// Private Use Area characters — CommonMark-inert, not touched by the renderer's
// HTML escape (which only rewrites `& < > "`), and vanishingly unlikely to
// appear in user content.
let footnoteSentinelOpen: Character = "\u{E000}"
let footnoteSentinelClose: Character = "\u{E001}"

func footnoteReferenceSentinel(number: Int) -> String {
	"\(footnoteSentinelOpen)fnref:\(number)\(footnoteSentinelClose)"
}

// MARK: - State

final class FootnoteState {
	private let validIDs: Set<String>
	private var numberByID: [String: Int] = [:]
	private var nextNumber = 1
	private var totalReferenceCountByNumber: [Int: Int] = [:]
	private var emittedReferenceCountByNumber: [Int: Int] = [:]

	init(definitionIDs: [String]) {
		self.validIDs = Set(definitionIDs)
	}

	/// Assigns and returns the number for `id` on first reference. Returns
	/// `nil` if no matching definition was extracted — callers then leave the
	/// `[^id]` substring as literal text.
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

struct FootnoteReferenceRewriter: MarkupRewriter {
	let state: FootnoteState

	mutating func visitText(_ text: Text) -> Markup? {
		let original = text.string
		guard original.contains("[^") else { return text }
		let rewritten = replaceReferences(in: original)
		guard rewritten != original else { return text }
		return Text(rewritten)
	}

	private func replaceReferences(in input: String) -> String {
		// The scan rules (bounds, valid-id shape, skip-unmatched) live in
		// `scanFootnoteReferences`; here we just turn the events into the
		// sentinel string the HTML pass later expands.
		var result = ""
		result.reserveCapacity(input.count)
		for event in scanFootnoteReferences(in: input, record: state.recordReference) {
			switch event {
			case .literal(let string):
				result += string
			case .reference(let number):
				result += footnoteReferenceSentinel(number: number)
			}
		}
		return result
	}
}
