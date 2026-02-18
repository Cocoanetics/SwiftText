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

			// Paragraph — collect consecutive non-blank, non-special lines
			var paraLines: [String] = []
			while i < lines.count {
				let pl = lines[i]
				let pt = pl.trimmingCharacters(in: .whitespaces)
				if pt.isEmpty || pt.hasPrefix("#") || pt.hasPrefix(">") || isHorizontalRule(pt) || isUnorderedListItem(pt) || orderedListContent(pt) != nil {
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
