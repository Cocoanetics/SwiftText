import Foundation

/// Converts Markdown text to a DOCX file.
///
/// Usage:
/// ```swift
/// try MarkdownToDocx.convert(markdownString, to: outputURL)
/// ```
public enum MarkdownToDocx {

	/// Converts Markdown text to a DOCX file at the given URL.
	/// - Parameters:
	///   - markdown: The Markdown source text.
	///   - url: Destination file URL for the `.docx` output.
	///   - pageSetup: Page configuration (paper size, margins, orientation). Defaults to A4 portrait.
	public static func convert(_ markdown: String, to url: URL, pageSetup: DocxPageSetup = .a4) throws {
		let blocks = parseBlocks(markdown)
		let writer = DocxWriter()
		writer.blocks = blocks
		writer.pageSetup = pageSetup
		try writer.write(to: url)
	}

	/// Parses Markdown text into an array of ``DocxWriter/Block`` elements.
	public static func parseBlocks(_ markdown: String) -> [DocxWriter.Block] {
		let lines = markdown.components(separatedBy: "\n")
		var blocks: [DocxWriter.Block] = []
		var i = 0

		while i < lines.count {
			let line = lines[i]
			let trimmed = line.trimmingCharacters(in: .whitespaces)

			// Blank line — skip
			if trimmed.isEmpty {
				i += 1
				continue
			}

			// Fenced code block
			if trimmed.hasPrefix("```") {
				let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
				let lang: String? = language.isEmpty ? nil : language
				i += 1
				var codeLines: [String] = []
				while i < lines.count {
					if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
						i += 1
						break
					}
					codeLines.append(lines[i])
					i += 1
				}
				blocks.append(.codeBlock(language: lang, text: codeLines.joined(separator: "\n")))
				continue
			}

			// Heading
			if let (level, content) = parseHeading(trimmed) {
				blocks.append(.heading(level: level, runs: parseInline(content)))
				i += 1
				continue
			}

			// Horizontal rule
			if isHorizontalRule(trimmed) {
				blocks.append(.horizontalRule)
				i += 1
				continue
			}

			// Blockquote
			if trimmed.hasPrefix(">") {
				var quoteLines: [String] = []
				while i < lines.count {
					let ql = lines[i].trimmingCharacters(in: .whitespaces)
					guard ql.hasPrefix(">") else { break }
					let content = String(ql.dropFirst()).trimmingCharacters(in: .whitespaces)
					quoteLines.append(content)
					i += 1
				}
				let innerBlocks = parseBlocks(quoteLines.joined(separator: "\n"))
				blocks.append(.blockquote(blocks: innerBlocks))
				continue
			}

			// Unordered list
			if isUnorderedListItem(trimmed) {
				while i < lines.count {
					let il = lines[i]
					let it = il.trimmingCharacters(in: .whitespaces)
					guard isUnorderedListItem(it) else { break }
					let level = indentLevel(il)
					let content = stripListMarker(it)
					blocks.append(.listItem(ordered: false, level: level, runs: parseInline(content)))
					i += 1
				}
				continue
			}

			// Ordered list
			if orderedListContent(trimmed) != nil {
				while i < lines.count {
					let il = lines[i]
					let it = il.trimmingCharacters(in: .whitespaces)
					guard let content = orderedListContent(it) else { break }
					let level = indentLevel(il)
					blocks.append(.listItem(ordered: true, level: level, runs: parseInline(content)))
					i += 1
				}
				continue
			}

			// Paragraph — collect consecutive non-blank, non-special lines
			var paraLines: [String] = []
			while i < lines.count {
				let pl = lines[i]
				let pt = pl.trimmingCharacters(in: .whitespaces)
				if pt.isEmpty || pt.hasPrefix("#") || pt.hasPrefix(">") || pt.hasPrefix("```") ||
					isHorizontalRule(pt) || isUnorderedListItem(pt) || orderedListContent(pt) != nil {
					break
				}
				paraLines.append(pt)
				i += 1
			}
			if !paraLines.isEmpty {
				let combined = paraLines.joined(separator: " ")
				blocks.append(.paragraph(runs: parseInline(combined)))
			}
		}

		return blocks
	}

	// MARK: - Block Helpers

	private static func parseHeading(_ line: String) -> (Int, String)? {
		var level = 0
		for ch in line {
			guard ch == "#" else { break }
			level += 1
		}
		guard level >= 1, level <= 6 else { return nil }
		guard line.count > level else { return (level, "") }
		let idx = line.index(line.startIndex, offsetBy: level)
		guard line[idx] == " " else { return nil }
		let content = String(line[line.index(after: idx)...])
		return (level, content)
	}

	private static func isHorizontalRule(_ line: String) -> Bool {
		let stripped = line.replacingOccurrences(of: " ", with: "")
		guard stripped.count >= 3 else { return false }
		let chars = Set(stripped)
		return chars.count == 1 && (chars.contains("-") || chars.contains("*") || chars.contains("_"))
	}

	private static func isUnorderedListItem(_ line: String) -> Bool {
		line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
	}

	private static func stripListMarker(_ line: String) -> String {
		String(line.dropFirst(2))
	}

	private static func orderedListContent(_ line: String) -> String? {
		guard let dotIndex = line.firstIndex(of: ".") else { return nil }
		let prefix = line[line.startIndex..<dotIndex]
		guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return nil }
		let afterDot = line.index(after: dotIndex)
		guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
		return String(line[line.index(after: afterDot)...])
	}

	private static func indentLevel(_ line: String) -> Int {
		var spaces = 0
		for ch in line {
			if ch == " " { spaces += 1 }
			else if ch == "\t" { spaces += 4 }
			else { break }
		}
		return spaces / 4
	}

	// MARK: - Inline Parser

	/// Parses inline Markdown formatting into DocxWriter runs.
	public static func parseInline(_ text: String) -> [DocxWriter.Run] {
		var runs: [DocxWriter.Run] = []
		let chars = Array(text)
		var i = 0
		var current = ""

		func flush() {
			guard !current.isEmpty else { return }
			runs.append(.init(text: current))
			current = ""
		}

		while i < chars.count {
			// Inline code: `…`
			if chars[i] == "`" {
				flush()
				i += 1
				var code = ""
				while i < chars.count, chars[i] != "`" {
					code.append(chars[i])
					i += 1
				}
				if i < chars.count { i += 1 } // skip closing `
				runs.append(.init(text: code, code: true))
				continue
			}

			// Image: ![alt](url) — use alt text as placeholder
			if chars[i] == "!", i + 1 < chars.count, chars[i + 1] == "[" {
				if let (alt, _, end) = parseLinkOrImage(chars, from: i + 1) {
					flush()
					let display = alt.isEmpty ? "[image]" : alt
					runs.append(.init(text: display, italic: true))
					i = end
					continue
				}
			}

			// Link: [text](url)
			if chars[i] == "[" {
				if let (text, url, end) = parseLinkOrImage(chars, from: i) {
					flush()
					runs.append(.init(text: text, link: url))
					i = end
					continue
				}
			}

			// Bold + italic: ***…***
			if i + 2 < chars.count, chars[i] == "*", chars[i + 1] == "*", chars[i + 2] == "*" {
				if let (content, end) = parseDelimited(chars, from: i, delimiter: "***") {
					flush()
					runs.append(.init(text: content, bold: true, italic: true))
					i = end
					continue
				}
			}

			// Bold: **…** or __…__
			if i + 1 < chars.count, chars[i] == "*", chars[i + 1] == "*" {
				if let (content, end) = parseDelimited(chars, from: i, delimiter: "**") {
					flush()
					runs.append(.init(text: content, bold: true))
					i = end
					continue
				}
			}
			if i + 1 < chars.count, chars[i] == "_", chars[i + 1] == "_" {
				if let (content, end) = parseDelimited(chars, from: i, delimiter: "__") {
					flush()
					runs.append(.init(text: content, bold: true))
					i = end
					continue
				}
			}

			// Italic: *…* or _…_
			if chars[i] == "*" {
				if let (content, end) = parseDelimited(chars, from: i, delimiter: "*") {
					flush()
					runs.append(.init(text: content, italic: true))
					i = end
					continue
				}
			}
			if chars[i] == "_" {
				if let (content, end) = parseDelimited(chars, from: i, delimiter: "_") {
					flush()
					runs.append(.init(text: content, italic: true))
					i = end
					continue
				}
			}

			current.append(chars[i])
			i += 1
		}

		flush()
		return runs
	}

	/// Finds `delimiter…delimiter` starting at position `from`, returns (content, endIndex).
	private static func parseDelimited(_ chars: [Character], from: Int, delimiter: String) -> (String, Int)? {
		let delimChars = Array(delimiter)
		let delimLen = delimChars.count

		// Verify opening delimiter
		guard from + delimLen <= chars.count else { return nil }
		for j in 0..<delimLen {
			guard chars[from + j] == delimChars[j] else { return nil }
		}

		let contentStart = from + delimLen
		var searchIdx = contentStart
		while searchIdx + delimLen <= chars.count {
			var match = true
			for j in 0..<delimLen {
				if chars[searchIdx + j] != delimChars[j] { match = false; break }
			}
			if match {
				let content = String(chars[contentStart..<searchIdx])
				guard !content.isEmpty else { return nil }
				return (content, searchIdx + delimLen)
			}
			searchIdx += 1
		}
		return nil
	}

	/// Parses `[text](url)` starting at `[`. Returns (text, url, endIndex).
	private static func parseLinkOrImage(_ chars: [Character], from: Int) -> (String, String, Int)? {
		guard from < chars.count, chars[from] == "[" else { return nil }

		// Find closing ]
		var j = from + 1
		var depth = 1
		while j < chars.count, depth > 0 {
			if chars[j] == "[" { depth += 1 }
			if chars[j] == "]" { depth -= 1 }
			if depth > 0 { j += 1 }
		}
		guard j < chars.count, chars[j] == "]" else { return nil }
		let text = String(chars[(from + 1)..<j])

		// Expect (
		let parenStart = j + 1
		guard parenStart < chars.count, chars[parenStart] == "(" else { return nil }

		// Find closing )
		var k = parenStart + 1
		while k < chars.count, chars[k] != ")" {
			k += 1
		}
		guard k < chars.count else { return nil }
		let url = String(chars[(parenStart + 1)..<k])

		return (text, url, k + 1)
	}
}
