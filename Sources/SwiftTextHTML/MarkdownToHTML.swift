import Foundation

/// Lightweight Markdown to HTML converter.
///
/// Supports: paragraphs, headings (h1–h6), bold, italic, inline code, links,
/// images, blockquotes, unordered/ordered lists, horizontal rules, and line breaks.
///
/// Usage:
/// ```swift
/// let html = MarkdownToHTML.convert("# Hello\n\nThis is **bold**.")
/// let text = MarkdownToHTML.stripToPlainText("**bold** and [link](https://example.com)")
/// ```
public enum MarkdownToHTML {

	// MARK: - Public API

	/// Converts a Markdown string to an HTML fragment.
	public static func convert(_ markdown: String) -> String {
		let lines = markdown.components(separatedBy: "\n")
		var html: [String] = []
		var i = 0

		while i < lines.count {
			let line = lines[i]

			// Blank line — skip (paragraph breaks handled by grouping)
			if line.trimmingCharacters(in: .whitespaces).isEmpty {
				i += 1
				continue
			}

			// Heading
			if let heading = parseHeading(line) {
				html.append(heading)
				i += 1
				continue
			}

			// Horizontal rule
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if isHorizontalRule(trimmed) {
				html.append("<hr>")
				i += 1
				continue
			}

			// Blockquote block
			if trimmed.hasPrefix(">") {
				var quoteLines: [String] = []
				while i < lines.count {
					let ql = lines[i].trimmingCharacters(in: .whitespaces)
					guard ql.hasPrefix(">") else { break }
					let content = String(ql.dropFirst()).trimmingCharacters(in: .whitespaces)
					quoteLines.append(content)
					i += 1
				}
				let inner = convert(quoteLines.joined(separator: "\n"))
				html.append("<blockquote>\(inner)</blockquote>")
				continue
			}

			// Unordered list
			if isUnorderedListItem(trimmed) {
				var items: [String] = []
				while i < lines.count {
					let il = lines[i].trimmingCharacters(in: .whitespaces)
					guard isUnorderedListItem(il) else { break }
					let content = String(il.dropFirst(2))
					items.append("<li>\(inlineFormat(content))</li>")
					i += 1
				}
				html.append("<ul>\(items.joined())</ul>")
				continue
			}

			// Ordered list
			if orderedListContent(trimmed) != nil {
				var items: [String] = []
				while i < lines.count {
					let il = lines[i].trimmingCharacters(in: .whitespaces)
					guard let content = orderedListContent(il) else { break }
					items.append("<li>\(inlineFormat(content))</li>")
					i += 1
				}
				html.append("<ol>\(items.joined())</ol>")
				continue
			}

			// Pipe table (| col | col |)
			if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"),
			   i + 1 < lines.count {
				let nextTrimmed = lines[i + 1].trimmingCharacters(in: .whitespaces)
				if nextTrimmed.hasPrefix("|"), nextTrimmed.hasSuffix("|"),
				   nextTrimmed.contains("-") {
					let sepCells = nextTrimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
					let isSeparator = sepCells.allSatisfy { cell in
						let stripped = cell.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
						return stripped.isEmpty && cell.contains("-")
					}
					if isSeparator {
						// Parse alignment from separator
						let alignments: [String] = sepCells.map { cell in
							let left = cell.hasPrefix(":")
							let right = cell.hasSuffix(":")
							if left && right { return " style=\"text-align: center;\"" }
							if right { return " style=\"text-align: right;\"" }
							return ""
						}
						// Header row
						let headerCells = trimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
						var table = "<table>\n<thead><tr>"
						for (ci, cell) in headerCells.enumerated() {
							let align = ci < alignments.count ? alignments[ci] : ""
							table += "<th\(align)>\(inlineFormat(cell))</th>"
						}
						table += "</tr></thead>\n<tbody>\n"
						// Skip header and separator
						i += 2
						// Body rows
						while i < lines.count {
							let rowTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
							guard rowTrimmed.hasPrefix("|"), rowTrimmed.hasSuffix("|") else { break }
							let rowCells = rowTrimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
							table += "<tr>"
							for (ci, cell) in rowCells.enumerated() {
								let align = ci < alignments.count ? alignments[ci] : ""
								table += "<td\(align)>\(inlineFormat(cell))</td>"
							}
							table += "</tr>\n"
							i += 1
						}
						table += "</tbody></table>"
						html.append(table)
						continue
					}
				}
			}

			// Paragraph — collect consecutive non-blank, non-special lines
			var paraLines: [String] = []
			while i < lines.count {
				let pl = lines[i]
				let pt = pl.trimmingCharacters(in: .whitespaces)
				if pt.isEmpty || pt.hasPrefix("#") || pt.hasPrefix(">") || isHorizontalRule(pt) || isUnorderedListItem(pt) || orderedListContent(pt) != nil || isPipeTableStart(lines: lines, at: i) {
					break
				}
				paraLines.append(pl)
				i += 1
			}
			let paraContent = paraLines.map { inlineFormat($0) }.joined(separator: "<br>\n")
			html.append("<p>\(paraContent)</p>")
		}

		return html.joined(separator: "\n")
	}

	/// Default stylesheet for Markdown HTML output.
	///
	/// Provides sensible styling for all supported elements: body, headings, paragraphs,
	/// lists, blockquotes, code blocks, tables, images, and horizontal rules.
	public static let defaultStylesheet = """
	body {
	    font-family: -apple-system, "Helvetica Neue", Arial, sans-serif;
	    font-size: 11pt;
	    line-height: 1.6;
	    color: #222;
	    max-width: 960px;
	    margin: 0 auto;
	    padding: 2em;
	}
	h1, h2, h3, h4, h5, h6 { font-weight: 600; margin: 1.2em 0 0.4em; line-height: 1.3; }
	h1 { font-size: 2em; border-bottom: 2px solid #ddd; padding-bottom: 0.2em; }
	h2 { font-size: 1.5em; border-bottom: 1px solid #eee; padding-bottom: 0.1em; }
	h3 { font-size: 1.25em; }
	p { margin: 0.6em 0; }
	ul, ol { margin: 0.6em 0; padding-left: 1.8em; }
	li { margin: 0.2em 0; }
	blockquote { border-left: 4px solid #ccc; padding: 0.3em 1em; margin: 0.6em 0; color: #555; }
	code {
	    font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
	    font-size: 0.88em; background: #f5f5f5; border: 1px solid #e0e0e0;
	    border-radius: 3px; padding: 0.1em 0.4em;
	}
	pre {
	    background: #f5f5f5; border: 1px solid #e0e0e0; border-radius: 4px;
	    padding: 0.8em; margin: 0.8em 0; overflow: auto; line-height: 1.2;
	    font-size: 10pt; white-space: pre-wrap; word-break: break-all;
	}
	pre code { background: none; border: none; padding: 0; font-size: inherit; }
	table { border-collapse: collapse; width: 100%; margin: 0.8em 0; font-size: 0.95em; }
	th, td { border: 1px solid #999; padding: 0.4em 0.7em; text-align: left; }
	th { background: #dcdcdc; font-weight: 600; }
	tr:nth-child(even) td { background: #f9f9f9; }
	img { max-width: 100%; height: auto; }
	hr { border: none; border-top: 1px solid #ddd; margin: 1.2em 0; }
	a { color: #0366d6; }
	"""

	/// Converts a Markdown string to a complete HTML document.
	///
	/// Wraps the converted fragment in `<!DOCTYPE html><html>…</html>` with a
	/// `<style>` block. Uses ``defaultStylesheet`` when no custom stylesheet is provided.
	///
	/// - Parameters:
	///   - markdown: The Markdown source text.
	///   - stylesheet: CSS to include in a `<style>` tag. Defaults to ``defaultStylesheet``.
	/// - Returns: A complete HTML document string.
	public static func document(_ markdown: String, stylesheet: String? = nil) -> String {
		let body = convert(markdown)
		let css = stylesheet ?? defaultStylesheet
		return """
		<!DOCTYPE html>
		<html>
		<head>
		<meta charset="utf-8">
		<style>
		\(css)
		</style>
		</head>
		<body>
		\(body)
		</body>
		</html>
		"""
	}

	/// Strips Markdown formatting to produce plain text.
	public static func stripToPlainText(_ markdown: String) -> String {
		var text = markdown

		// Remove images ![alt](url) → alt
		text = text.replacingOccurrences(
			of: #"!\[([^\]]*)\]\([^\)]+\)"#,
			with: "$1",
			options: .regularExpression
		)

		// Convert links [text](url) → text
		text = text.replacingOccurrences(
			of: #"\[([^\]]+)\]\([^\)]+\)"#,
			with: "$1",
			options: .regularExpression
		)

		// Remove bold/italic markers
		text = text.replacingOccurrences(
			of: #"\*\*(.+?)\*\*"#,
			with: "$1",
			options: .regularExpression
		)
		text = text.replacingOccurrences(
			of: #"__(.+?)__"#,
			with: "$1",
			options: .regularExpression
		)
		text = text.replacingOccurrences(
			of: #"\*(.+?)\*"#,
			with: "$1",
			options: .regularExpression
		)
		text = text.replacingOccurrences(
			of: #"_(.+?)_"#,
			with: "$1",
			options: .regularExpression
		)

		// Remove inline code backticks
		text = text.replacingOccurrences(
			of: #"`(.+?)`"#,
			with: "$1",
			options: .regularExpression
		)

		// Strip heading markers
		text = text.replacingOccurrences(
			of: #"(?m)^#{1,6}\s+"#,
			with: "",
			options: .regularExpression
		)

		// Strip blockquote markers
		text = text.replacingOccurrences(
			of: #"(?m)^>\s?"#,
			with: "",
			options: .regularExpression
		)

		// Strip horizontal rules
		text = text.replacingOccurrences(
			of: #"(?m)^[-*_]{3,}\s*$"#,
			with: "---",
			options: .regularExpression
		)

		return text
	}

	// MARK: - Block Parsing

	private static func parseHeading(_ line: String) -> String? {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		var level = 0
		for ch in trimmed {
			guard ch == "#" else { break }
			level += 1
		}
		guard level >= 1, level <= 6 else { return nil }
		guard trimmed.count > level, trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == " " else { return nil }
		let content = String(trimmed.dropFirst(level + 1))
		return "<h\(level)>\(inlineFormat(content))</h\(level)>"
	}

	private static func isHorizontalRule(_ line: String) -> Bool {
		let stripped = line.replacingOccurrences(of: " ", with: "")
		guard stripped.count >= 3 else { return false }
		let chars = Set(stripped)
		return chars.count == 1 && (chars.contains("-") || chars.contains("*") || chars.contains("_"))
	}

	private static func isPipeTableStart(lines: [String], at index: Int) -> Bool {
		let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
		guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|"),
			  index + 1 < lines.count else { return false }
		let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
		guard next.hasPrefix("|"), next.hasSuffix("|"), next.contains("-") else { return false }
		let cells = next.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
		return cells.allSatisfy { cell in
			let stripped = cell.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
			return stripped.isEmpty && cell.contains("-")
		}
	}

	private static func isUnorderedListItem(_ line: String) -> Bool {
		line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
	}

	private static func orderedListContent(_ line: String) -> String? {
		guard let dotIndex = line.firstIndex(of: ".") else { return nil }
		let prefix = line[line.startIndex..<dotIndex]
		guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return nil }
		let afterDot = line.index(after: dotIndex)
		guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
		return String(line[line.index(after: afterDot)...])
	}

	// MARK: - Inline Formatting

	/// Processes inline formatting: bold, italic, code, links, images.
	private static func inlineFormat(_ text: String) -> String {
		var result = escapeHTML(text)

		// Code (before bold/italic to avoid interference)
		result = result.replacingOccurrences(
			of: #"`(.+?)`"#,
			with: "<code>$1</code>",
			options: .regularExpression
		)

		// Images ![alt](url)
		result = result.replacingOccurrences(
			of: #"!\[([^\]]*)\]\(([^\)]+)\)"#,
			with: #"<img src="$2" alt="$1">"#,
			options: .regularExpression
		)

		// Links [text](url)
		result = result.replacingOccurrences(
			of: #"\[([^\]]+)\]\(([^\)]+)\)"#,
			with: #"<a href="$2">$1</a>"#,
			options: .regularExpression
		)

		// Bold **text** or __text__
		result = result.replacingOccurrences(
			of: #"\*\*(.+?)\*\*"#,
			with: "<strong>$1</strong>",
			options: .regularExpression
		)
		result = result.replacingOccurrences(
			of: #"__(.+?)__"#,
			with: "<strong>$1</strong>",
			options: .regularExpression
		)

		// Italic *text* or _text_
		result = result.replacingOccurrences(
			of: #"\*(.+?)\*"#,
			with: "<em>$1</em>",
			options: .regularExpression
		)
		result = result.replacingOccurrences(
			of: #"(?<!\w)_(.+?)_(?!\w)"#,
			with: "<em>$1</em>",
			options: .regularExpression
		)

		return result
	}

	private static func escapeHTML(_ text: String) -> String {
		text.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
	}
}
