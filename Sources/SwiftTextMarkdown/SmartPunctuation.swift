//
//  SmartPunctuation.swift
//  SwiftText
//

import Foundation

/// Typographic punctuation for Markdown source, like pandoc's `smart` extension:
/// straight quotes and apostrophes become curly, `--` an en dash, `---` an em dash
/// and `...` an ellipsis.
///
/// Works on the Markdown text, so every output format gets the same result. Code
/// (spans, fenced and indented blocks), raw HTML, URLs, link destinations,
/// `[^id]` / `[n]` markers, front matter and backslash escapes are left alone.
/// Only ASCII characters are ever replaced, so literal typographic characters in the
/// input survive unchanged.
public enum SmartPunctuation {
	/// Quotation marks of a language.
	struct Quotes {
		var open: Character
		var close: Character
		var singleOpen: Character
		var singleClose: Character
	}

	static func quotes(forLanguage language: String) -> Quotes {
		let primary = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en"
		switch primary {
		case "de", "cs", "sk", "sl", "hr":
			return Quotes(open: "\u{201E}", close: "\u{201C}", singleOpen: "\u{201A}", singleClose: "\u{2018}")
		case "fr", "es", "it", "ru", "uk":
			return Quotes(open: "\u{00AB}", close: "\u{00BB}", singleOpen: "\u{2039}", singleClose: "\u{203A}")
		case "sv", "fi":
			return Quotes(open: "\u{201D}", close: "\u{201D}", singleOpen: "\u{2019}", singleClose: "\u{2019}")
		default:
			return Quotes(open: "\u{201C}", close: "\u{201D}", singleOpen: "\u{2018}", singleClose: "\u{2019}")
		}
	}

	/// Returns `markdown` with smart punctuation applied; `language` is a BCP-47 tag choosing the quote style.
	public static func apply(to markdown: String, language: String = "en") -> String {
		let quotes = quotes(forLanguage: language)
		let lines = markdown.components(separatedBy: "\n")
		var result: [String] = []
		result.reserveCapacity(lines.count)

		var fence: (marker: Character, length: Int)?
		var rawBlockEnd: String?
		var inFrontMatter = false
		var inList = false
		var openSpan: Int?
		let labels = Set(lines.compactMap { referenceLabel(of: $0.trimmingCharacters(in: .whitespaces)) })

		/// Whether a code span opened by a run of `length` backticks closes later in the same paragraph.
		func closes(after index: Int) -> (Int) -> Bool {
			{ length in
				for next in lines[(index + 1)...] {
					if next.trimmingCharacters(in: .whitespaces).isEmpty { return false }
					if closingBacktickRun(Array(next), from: 0, length: length) != nil { return true }
				}
				return false
			}
		}

		for (index, line) in lines.enumerated() {
			let trimmed = line.trimmingCharacters(in: .whitespaces)

			if index == 0, trimmed == "---",
			   lines.dropFirst().contains(where: { $0.trimmingCharacters(in: .whitespaces) == "---" || $0.trimmingCharacters(in: .whitespaces) == "..." }) {
				inFrontMatter = true
				result.append(line)
				continue
			}
			if inFrontMatter {
				if trimmed == "---" || trimmed == "..." { inFrontMatter = false }
				result.append(line)
				continue
			}

			if let open = fence {
				let content = strippingQuoteMarkers(trimmed)
				if let closing = fenceMarker(of: content), closing.marker == open.marker, closing.length >= open.length,
				   content.allSatisfy({ $0 == open.marker }) {
					fence = nil
				}
				result.append(line)
				continue
			}
			if let end = rawBlockEnd {
				if line.lowercased().contains(end) { rawBlockEnd = nil }
				result.append(line)
				continue
			}

			let blank = trimmed.isEmpty
			if blank {
				result.append(line)
				continue
			}

			// Continuation of a code span that opened on an earlier line.
			if let run = openSpan {
				let chars = Array(line)
				if let end = closingBacktickRun(chars, from: 0, length: run) {
					openSpan = nil
					let (rest, pending) = convertInline(String(chars[end...]), quotes: quotes, labels: labels, closes: closes(after: index))
					openSpan = pending
					result.append(String(chars[..<end]) + rest)
				} else {
					result.append(line)
				}
				continue
			}

			let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
			if indent < 4 || inList, let marker = fenceMarker(of: strippingQuoteMarkers(trimmed)) {
				fence = marker
				result.append(line)
				continue
			}
			if indent >= 4, !inList {
				// Indented code block.
				result.append(line)
				continue
			}
			if indent == 0, !isListItem(trimmed) { inList = false }
			if isListItem(trimmed) { inList = true }

			let lower = trimmed.lowercased()
			if lower.hasPrefix("<!--"), !lower.contains("-->") {
				rawBlockEnd = "-->"
				result.append(line)
				continue
			}
			if let tag = ["pre", "script", "style"].first(where: { lower.hasPrefix("<\($0)") }) {
				if !lower.contains("</\(tag)>") { rawBlockEnd = "</\(tag)>" }
				result.append(line)
				continue
			}
			// Thematic breaks, setext underlines and table delimiter rows.
			if trimmed.allSatisfy({ "-*_=|: ".contains($0) }) || isReferenceDefinition(trimmed) {
				result.append(line)
				continue
			}

			let (converted, pending) = convertInline(line, quotes: quotes, labels: labels, dashes: !isUnattributedHeading(trimmed),
			                                         closes: closes(after: index))
			openSpan = pending
			result.append(converted)
		}
		return result.joined(separator: "\n")
	}

	// MARK: - Block helpers

	private static func fenceMarker(of trimmed: String) -> (marker: Character, length: Int)? {
		guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
		let length = trimmed.prefix(while: { $0 == first }).count
		return length >= 3 ? (first, length) : nil
	}

	/// Removes leading block-quote markers (`> `), so a fence inside a quote is recognised.
	private static func strippingQuoteMarkers(_ trimmed: String) -> String {
		var rest = Substring(trimmed)
		while rest.first == ">" {
			rest = rest.dropFirst().drop(while: { $0 == " " })
		}
		return String(rest)
	}

	private static func isListItem(_ trimmed: String) -> Bool {
		guard let first = trimmed.first else { return false }
		if "-*+".contains(first) { return trimmed.dropFirst().first == " " }
		let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
		guard !digits.isEmpty else { return false }
		let rest = trimmed.dropFirst(digits.count)
		return (rest.first == "." || rest.first == ")") && rest.dropFirst().first == " "
	}

	/// The normalised label of a `[label]: destination` definition.
	private static func referenceLabel(of trimmed: String) -> String? {
		guard isReferenceDefinition(trimmed), let close = trimmed.firstIndex(of: "]") else { return nil }
		return normalizedLabel(String(trimmed[trimmed.index(after: trimmed.startIndex)..<close]))
	}

	private static func normalizedLabel(_ label: String) -> String {
		label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
	}

	/// An ATX heading without an explicit `{#id}`: its generated anchor slug depends on the
	/// literal hyphens, so dashes there stay as typed to keep `(#pros----cons)` links working.
	private static func isUnattributedHeading(_ trimmed: String) -> Bool {
		let hashes = trimmed.prefix(while: { $0 == "#" }).count
		guard (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " else { return false }
		return !trimmed.hasSuffix("}") || !trimmed.contains("{#")
	}

	/// `[label]: destination "title"` — but not a footnote definition `[^id]: text`, whose text is prose.
	private static func isReferenceDefinition(_ trimmed: String) -> Bool {
		guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[^"), let close = trimmed.firstIndex(of: "]") else { return false }
		return trimmed[trimmed.index(after: close)...].hasPrefix(":")
	}

	// MARK: - Inline conversion

	private static let emphasis: Set<Character> = ["*", "_", "~"]
	private static let openers: Set<Character> = ["(", "[", "{", "<", "/", "\u{2014}", "\u{2013}", "\u{201C}", "\u{2018}", "\u{201E}", "\u{201A}", "\u{00AB}"]

	/// Converts one line. When a code span opens here and closes on a later line (`closes` says so),
	/// the rest of the line is kept verbatim and the run length is returned as pending.
	private static func convertInline(_ line: String, quotes: Quotes, labels: Set<String>, dashes: Bool = true,
	                                  closes: (Int) -> Bool) -> (String, pending: Int?) {
		var pending: Int?
		let chars = Array(line)
		var out = ""
		var i = 0
		/// Last character before the cursor that is not an emphasis marker (line start counts as whitespace).
		var previous: Character = " "

		func append(_ s: some Sequence<Character>) {
			for c in s {
				out.append(c)
				if !emphasis.contains(c) { previous = c }
			}
		}
		func copyVerbatim(to end: Int) {
			append(chars[i..<end])
			i = end
		}

		while i < chars.count {
			let c = chars[i]
			switch c {
			case "\\":
				copyVerbatim(to: min(i + 2, chars.count))
			case "`":
				let run = chars[i...].prefix(while: { $0 == "`" }).count
				if let end = closingBacktickRun(chars, from: i + run, length: run) {
					copyVerbatim(to: end)
				} else if closes(run) {
					pending = run
					copyVerbatim(to: chars.count)
				} else {
					copyVerbatim(to: i + run)
				}
			case "<":
				if i + 1 < chars.count, chars[i + 1].isLetter || "/!?".contains(chars[i + 1]), let end = chars[i...].firstIndex(of: ">") {
					copyVerbatim(to: end + 1)
				} else {
					copyVerbatim(to: i + 1)
				}
			case "[":
				if let end = chars[i...].firstIndex(of: "]"),
				   isMarkerLabel(chars[(i + 1)..<end]) || labels.contains(normalizedLabel(String(chars[(i + 1)..<end]))) {
					copyVerbatim(to: end + 1)
				} else {
					copyVerbatim(to: i + 1)
				}
			case "]":
				copyVerbatim(to: i + 1)
				if i < chars.count, chars[i] == "(", let end = matchingParen(chars, from: i) {
					copyVerbatim(to: end + 1)
				}
			case "h", "H", "f", "w":
				if previous.isLetter || previous.isNumber || !startsURL(chars, at: i) {
					copyVerbatim(to: i + 1)
				} else {
					var end = i
					while end < chars.count, !chars[end].isWhitespace, chars[end] != "<" { end += 1 }
					while end > i, ".,;:!?\"')*_".contains(chars[end - 1]) { end -= 1 }
					copyVerbatim(to: max(end, i + 1))
				}
			case "{":
				// Heading / attribute lists such as `{#custom-id}` and `{.class}`.
				if i + 1 < chars.count, chars[i + 1] == "#" || chars[i + 1] == ".", let end = chars[i...].firstIndex(of: "}") {
					copyVerbatim(to: end + 1)
				} else {
					copyVerbatim(to: i + 1)
				}
			case "-":
				let run = chars[i...].prefix(while: { $0 == "-" }).count
				if !dashes {
					append(chars[i..<(i + run)])
				} else if run == 3 {
					append("\u{2014}")
				} else if run == 2 {
					append("\u{2013}")
				} else {
					append(chars[i..<(i + run)])
				}
				i += run
			case ".":
				var run = chars[i...].prefix(while: { $0 == "." }).count
				i += run
				while run >= 3 {
					append("\u{2026}")
					run -= 3
				}
				append(String(repeating: ".", count: run))
			case "\"", "'":
				var next: Character?
				var j = i + 1
				while j < chars.count, emphasis.contains(chars[j]) { j += 1 }
				if j < chars.count { next = chars[j] }

				let afterBoundary = previous.isWhitespace || openers.contains(previous)
				let beforeSpace = next.map { $0.isWhitespace } ?? true
				let replacement: Character
				if c == "'", afterBoundary, let next, next.isNumber {
					replacement = "\u{2019}" // '90s
				} else if afterBoundary, !beforeSpace {
					replacement = c == "\"" ? quotes.open : quotes.singleOpen
				} else if c == "'", previous.isLetter || previous.isNumber, let next, next.isLetter || next.isNumber {
					replacement = "\u{2019}" // apostrophe inside a word
				} else {
					replacement = c == "\"" ? quotes.close : quotes.singleClose
				}
				append([replacement])
				i += 1
			default:
				append([c])
				i += 1
			}
		}
		return (out, pending)
	}

	private static func closingBacktickRun(_ chars: [Character], from start: Int, length: Int) -> Int? {
		var i = start
		while i < chars.count {
			if chars[i] == "`" {
				let run = chars[i...].prefix(while: { $0 == "`" }).count
				if run == length { return i + run }
				i += run
			} else {
				i += 1
			}
		}
		return nil
	}

	/// `^id` footnote labels and all-digit `n` citation labels.
	private static func isMarkerLabel(_ label: ArraySlice<Character>) -> Bool {
		if label.first == "^" { return true }
		return !label.isEmpty && label.allSatisfy { $0.isASCII && $0.isNumber }
	}

	private static func matchingParen(_ chars: [Character], from open: Int) -> Int? {
		var depth = 0
		var i = open
		while i < chars.count {
			if chars[i] == "\\" { i += 2; continue }
			if chars[i] == "(" { depth += 1 }
			if chars[i] == ")" {
				depth -= 1
				if depth == 0 { return i }
			}
			i += 1
		}
		return nil
	}

	private static func startsURL(_ chars: [Character], at i: Int) -> Bool {
		let rest = String(chars[i..<min(i + 8, chars.count)]).lowercased()
		return rest.hasPrefix("http://") || rest.hasPrefix("https://") || rest.hasPrefix("ftp://") || rest.hasPrefix("www.")
	}
}
