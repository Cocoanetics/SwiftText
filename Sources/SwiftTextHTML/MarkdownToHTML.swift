import Foundation
import SwiftTextMarkdown

/// Markdown to HTML converter, backed by swift-markdown's CommonMark/GFM parser.
///
/// Supports the full GFM superset — paragraphs, headings (h1–h6), bold, italic,
/// strikethrough, inline code, autolinks, links, images, blockquotes, GitHub
/// alerts (`> [!NOTE]` etc.), DocC asides (`> Tip:`), unordered/ordered lists,
/// task lists, fenced/indented code blocks, pipe tables with alignment,
/// horizontal rules, hard/soft line breaks, link reference definitions, setext
/// headings, and escape sequences.
///
/// Usage:
/// ```swift
/// let html = MarkdownToHTML.convert("# Hello\n\nThis is **bold**.")
/// let text = MarkdownToHTML.stripToPlainText("**bold** and [link](https://example.com)")
/// ```
public enum MarkdownToHTML {

	// MARK: - Public API

	/// Converts a Markdown string to an HTML fragment.
	///
	/// Inputs that don't use the `[^id]` / `[^id]: …` footnote syntax round-trip
	/// through swift-markdown's renderer unchanged — the footnote layer's fast
	/// path skips straight to ``SwiftMarkdownHTMLRenderer/convert(_:)``. Inputs
	/// that do use it get definitions extracted, references rewritten in the
	/// AST, and a `<div class="footnote-definition">` block appended.
	public static func convert(_ markdown: String) -> String {
		MarkdownFootnoteRenderer.convert(markdown)
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
	.markdown-alert {
	    border-left-width: 4px;
	    border-left-style: solid;
	    border-radius: 6px;
	    margin: 0.8em 0;
	    padding: 0.75em 1em;
	}
	.markdown-alert-title {
	    font-weight: 600;
	    margin: 0 0 0.35em;
	}
	.markdown-alert > :last-child { margin-bottom: 0; }
	.markdown-alert-note { background: #ddf4ff; border-left-color: #0969da; color: #0a3069; }
	.markdown-alert-tip { background: #dafbe1; border-left-color: #1a7f37; color: #116329; }
	.markdown-alert-important { background: #fbefff; border-left-color: #8250df; color: #5521b5; }
	.markdown-alert-warning { background: #fff8c5; border-left-color: #9a6700; color: #7d4e00; }
	.markdown-alert-caution { background: #ffebe9; border-left-color: #cf222e; color: #a40e26; }
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
	table { border-collapse: collapse; margin: 0.8em 0; font-size: 0.95em; }
	th, td { border: 1px solid #999; padding: 0.4em 0.7em; text-align: left; }
	th { background: #dcdcdc; font-weight: 600; }
	tr:nth-child(even) td { background: #f9f9f9; }
	img { max-width: 100%; height: auto; }
	hr { border: none; border-top: 1px solid #ddd; margin: 1.2em 0; }
	a { color: #0366d6; }
	del { color: #777; }
	li.task-list-item { list-style: none; margin-left: -1.2em; }
	li.task-list-item input[type="checkbox"] { margin-right: 0.4em; vertical-align: middle; }
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
}
