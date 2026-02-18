//
//  PDFCommand.swift
//  SwiftText
//
//  Created by Oliver Drobnik on 18.02.26.
//

#if os(macOS)
import ArgumentParser
import Foundation
import SwiftTextHTML
import SwiftTextDOCX

// MARK: - Paper size

enum PaperSize: String, ExpressibleByArgument, CaseIterable {
	case a4
	case letter

	/// Page dimensions in points (portrait orientation).
	var pointSize: CGSize {
		switch self {
		case .a4:     return CGSize(width: 595.28, height: 841.89)
		case .letter: return CGSize(width: 612.0,  height: 792.0)
		}
	}

	/// CSS `@page` size keyword.
	var cssName: String {
		switch self {
		case .a4:     return "A4"
		case .letter: return "letter"
		}
	}
}

// MARK: - PDF subcommand

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct PDF: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "pdf",
		abstract: "Render an HTML, Markdown, DOCX, or EML file (or URL) to PDF via WebKit."
	)

	@Argument(help: "Path to an .html, .md, .docx, or .eml file, or an http(s) URL. Omit when using --stdin.")
	var input: String?

	@Flag(name: .long, help: "Read HTML from standard input instead of a file or URL.")
	var stdin: Bool = false

	@Option(name: .shortAndLong, help: "Output PDF path. Defaults to the input filename with a .pdf extension.")
	var output: String?

	@Option(name: .long, help: "Paper size: a4, letter (default: a4).")
	var paper: PaperSize = .a4

	@Flag(name: .long, help: "Use landscape orientation (default: portrait).")
	var landscape: Bool = false

	// MARK: - Run

	func run() async throws {
		guard #available(macOS 12.0, *) else {
			throw ValidationError("The pdf command requires macOS 12 or newer.")
		}

		if stdin {
			guard input == nil else {
				throw ValidationError("Provide either an input path/URL or --stdin, not both.")
			}
			let html = readAllStdin()
			let outputURL = resolvedOutputURL() ?? defaultOutputURL(stem: "output")
			try await renderHTML(html, sourceURL: nil, to: outputURL)
			print(outputURL.path)
			return
		}

		guard let input else {
			throw ValidationError("Provide an input path/URL, or use --stdin.")
		}

		// http/https URL — load directly in WebKit
		if let url = parseHTTPURL(input) {
			let outputURL = urlOutputURL(from: url)
			try await renderURL(url, to: outputURL)
			print(outputURL.path)
			return
		}

		// File path
		let fileURL = resolvedFileURL(input)
		guard FileManager.default.fileExists(atPath: fileURL.path) else {
			throw ValidationError("File not found: \(fileURL.path)")
		}
		let (html, baseURL) = try convertToHTML(fileURL: fileURL)
		let outputURL = fileOutputURL(from: fileURL)
		try await renderHTML(html, sourceURL: baseURL, to: outputURL)
		print(outputURL.path)
	}

	// MARK: - Input → HTML conversion

	/// Converts a file at the given URL to an HTML string plus an optional base URL
	/// for resolving relative assets.
	private func convertToHTML(fileURL: URL) throws -> (String, URL?) {
		let ext = fileURL.pathExtension.lowercased()
		let baseURL = fileURL.deletingLastPathComponent()

		switch ext {
		case "html", "htm":
			let data = try Data(contentsOf: fileURL)
			let html = String(data: data, encoding: .utf8)
				?? String(data: data, encoding: .isoLatin1)
				?? ""
			return (html, baseURL)

		case "md", "markdown":
			let md = try String(contentsOf: fileURL, encoding: .utf8)
			return (markdownToHTML(md, paper: paper, landscape: landscape), nil)

		case "docx":
			let docx = try DocxFile(url: fileURL)
			let md = docx.markdown()
			return (markdownToHTML(md, paper: paper, landscape: landscape), nil)

		case "eml":
			let raw = try String(contentsOf: fileURL, encoding: .utf8)
			guard let extracted = extractHTMLFromEML(raw) else {
				throw ValidationError("No HTML body found in EML file: \(fileURL.lastPathComponent)")
			}
			return (extracted, nil)

		default:
			throw ValidationError(
				"Unsupported file type '.\(ext)'. Supported: html, htm, md, markdown, docx, eml."
			)
		}
	}

	// MARK: - WebKit rendering

	/// Renders an HTML string to a PDF file using WebKit.
	@MainActor
	@available(macOS 12.0, *)
	private func renderHTML(_ html: String, sourceURL: URL?, to outputURL: URL) async throws {
		let browser = WebKitBrowser(htmlString: html, baseURL: sourceURL)
		await browser.waitForLoadCompletion()
		let pdfData = try await browser.exportPDFData()
		try writeData(pdfData, to: outputURL)
	}

	/// Loads a URL in WebKit and renders the result to a PDF file.
	@MainActor
	@available(macOS 12.0, *)
	private func renderURL(_ url: URL, to outputURL: URL) async throws {
		let browser = WebKitBrowser(url: url)
		await browser.waitForLoadCompletion()
		let pdfData = try await browser.exportPDFData()
		try writeData(pdfData, to: outputURL)
	}

	// MARK: - Output URL helpers

	private func resolvedOutputURL() -> URL? {
		guard let output else { return nil }
		let expanded = (output as NSString).expandingTildeInPath
		return URL(fileURLWithPath: expanded)
	}

	private func fileOutputURL(from fileURL: URL) -> URL {
		if let explicit = resolvedOutputURL() { return explicit }
		return fileURL.deletingPathExtension().appendingPathExtension("pdf")
	}

	private func urlOutputURL(from url: URL) -> URL {
		if let explicit = resolvedOutputURL() { return explicit }
		let base = url.deletingPathExtension().lastPathComponent
		let stem = base.isEmpty ? "output" : base
		return defaultOutputURL(stem: stem)
	}

	private func defaultOutputURL(stem: String) -> URL {
		URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
			.appendingPathComponent(stem)
			.appendingPathExtension("pdf")
	}

	// MARK: - Misc helpers

	private func resolvedFileURL(_ path: String) -> URL {
		let expanded = (path as NSString).expandingTildeInPath
		if expanded.hasPrefix("/") {
			return URL(fileURLWithPath: expanded)
		}
		return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
			.appendingPathComponent(expanded)
	}

	private func parseHTTPURL(_ s: String) -> URL? {
		guard let url = URL(string: s),
		      let scheme = url.scheme?.lowercased(),
		      scheme == "http" || scheme == "https" else { return nil }
		return url
	}

	private func readAllStdin() -> String {
		var lines: [String] = []
		while let line = readLine(strippingNewline: false) {
			lines.append(line)
		}
		return lines.joined()
	}

	private func writeData(_ data: Data, to url: URL) throws {
		let dir = url.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try data.write(to: url)
	}
}

// MARK: - Markdown → HTML

/// Converts a Markdown string to a self-contained HTML document
/// styled for print output and with CSS `@page` size directives.
private func markdownToHTML(_ markdown: String, paper: PaperSize, landscape: Bool) -> String {
	let orientation = landscape ? "landscape" : "portrait"
	let pageCSS = "\(paper.cssName) \(orientation)"
	let body = convertMarkdownBody(markdown)
	return """
	<!DOCTYPE html>
	<html lang="en">
	<head>
	<meta charset="utf-8">
	<meta name="viewport" content="width=device-width, initial-scale=1">
	<style>
	@page { size: \(pageCSS); margin: 2cm; }
	*, *::before, *::after { box-sizing: border-box; }
	body {
	    font-family: -apple-system, "Helvetica Neue", Arial, sans-serif;
	    font-size: 11pt;
	    line-height: 1.6;
	    color: #222;
	    margin: 0;
	    padding: 0;
	}
	h1, h2, h3, h4, h5, h6 { font-weight: 600; margin: 1.2em 0 0.4em; line-height: 1.3; }
	h1 { font-size: 2em;    border-bottom: 2px solid #ddd; padding-bottom: 0.2em; }
	h2 { font-size: 1.5em;  border-bottom: 1px solid #eee; padding-bottom: 0.1em; }
	h3 { font-size: 1.25em; }
	p  { margin: 0.6em 0; }
	ul, ol { margin: 0.6em 0; padding-left: 1.8em; }
	li { margin: 0.2em 0; }
	blockquote {
	    border-left: 4px solid #ccc;
	    padding: 0.3em 1em;
	    margin: 0.6em 0;
	    color: #555;
	}
	code {
	    font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
	    font-size: 0.88em;
	    background: #f5f5f5;
	    border: 1px solid #e0e0e0;
	    border-radius: 3px;
	    padding: 0.1em 0.4em;
	}
	pre {
	    background: #f5f5f5;
	    border: 1px solid #e0e0e0;
	    border-radius: 4px;
	    padding: 1em;
	    overflow: auto;
	}
	pre code { background: none; border: none; padding: 0; font-size: inherit; }
	table { border-collapse: collapse; width: 100%; margin: 0.8em 0; font-size: 0.95em; }
	th, td { border: 1px solid #ccc; padding: 0.4em 0.7em; text-align: left; }
	th { background: #f0f0f0; font-weight: 600; }
	tr:nth-child(even) td { background: #fafafa; }
	img { max-width: 100%; height: auto; }
	hr { border: none; border-top: 1px solid #ddd; margin: 1.2em 0; }
	a { color: #0366d6; }
	</style>
	</head>
	<body>
	\(body)
	</body>
	</html>
	"""
}

/// Converts the body of a Markdown document to HTML.
/// Handles: headings, fenced code blocks, blockquotes, unordered/ordered lists,
/// horizontal rules, bold, italic, inline code, links, images, and paragraphs.
private func convertMarkdownBody(_ markdown: String) -> String {
	let lines = markdown
		.replacingOccurrences(of: "\r\n", with: "\n")
		.replacingOccurrences(of: "\r",   with: "\n")
		.components(separatedBy: "\n")

	var out = ""
	var i = 0
	var inUL = false
	var inOL = false
	var inCode = false
	var codeAccum: [String] = []
	var codeLang = ""

	// Flush any open list tags
	func closeLists() {
		if inUL { out += "</ul>\n"; inUL = false }
		if inOL { out += "</ol>\n"; inOL = false }
	}

	while i < lines.count {
		let line = lines[i]

		// ── Fenced code block (``` lang) ─────────────────────────────
		if line.hasPrefix("```") {
			if inCode {
				// Closing fence
				let escaped = codeAccum.map { htmlEscape($0) }.joined(separator: "\n")
				let attr = codeLang.isEmpty ? "" : " class=\"language-\(htmlEscape(codeLang))\""
				out += "<pre><code\(attr)>\(escaped)</code></pre>\n"
				inCode = false; codeAccum = []; codeLang = ""
			} else {
				// Opening fence
				closeLists()
				inCode = true
				codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
			}
			i += 1; continue
		}
		if inCode { codeAccum.append(line); i += 1; continue }

		// ── ATX headings (#…) ─────────────────────────────────────────
		if line.hasPrefix("#") {
			var level = 0
			for ch in line { guard ch == "#" else { break }; level += 1 }
			if level <= 6, line.count > level, line[line.index(line.startIndex, offsetBy: level)] == " " {
				closeLists()
				let text = String(line.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
				out += "<h\(level)>\(inlineToHTML(text))</h\(level)>\n"
				i += 1; continue
			}
		}

		// ── Horizontal rule (---, ***, ___) ──────────────────────────
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		if !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "-" || $0 == " " }),
		   trimmed.filter({ $0 == "-" }).count >= 3 {
			closeLists()
			out += "<hr>\n"
			i += 1; continue
		}
		if trimmed == "***" || trimmed == "___" {
			closeLists()
			out += "<hr>\n"
			i += 1; continue
		}

		// ── Blockquote (> …) ─────────────────────────────────────────
		if line.hasPrefix("> ") || line == ">" {
			closeLists()
			var qLines: [String] = []
			while i < lines.count, lines[i].hasPrefix("> ") || lines[i] == ">" {
				qLines.append(lines[i].hasPrefix("> ") ? String(lines[i].dropFirst(2)) : "")
				i += 1
			}
			let inner = convertMarkdownBody(qLines.joined(separator: "\n"))
			out += "<blockquote>\n\(inner)</blockquote>\n"
			continue
		}

		// ── Unordered list (- / * / +) ────────────────────────────────
		if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
			if inOL { out += "</ol>\n"; inOL = false }
			if !inUL { out += "<ul>\n"; inUL = true }
			let text = String(line.dropFirst(2))
			out += "<li>\(inlineToHTML(text))</li>\n"
			i += 1; continue
		}

		// ── Ordered list (1. 2. …) ───────────────────────────────────
		if let spaceIdx = line.firstIndex(of: " "),
		   line[..<spaceIdx].hasSuffix("."),
		   let _ = Int(String(line[..<line.index(before: spaceIdx)])) {
			if inUL { out += "</ul>\n"; inUL = false }
			if !inOL { out += "<ol>\n"; inOL = true }
			let text = String(line[line.index(after: spaceIdx)...])
			out += "<li>\(inlineToHTML(text))</li>\n"
			i += 1; continue
		}

		// ── Blank line ────────────────────────────────────────────────
		if trimmed.isEmpty {
			closeLists()
			out += "\n"
			i += 1; continue
		}

		// ── Plain paragraph ───────────────────────────────────────────
		closeLists()
		var paraLines: [String] = []
		while i < lines.count {
			let cur = lines[i]
			let curTrimmed = cur.trimmingCharacters(in: .whitespaces)
			if curTrimmed.isEmpty { break }
			if cur.hasPrefix("#") || cur.hasPrefix("```") { break }
			if cur.hasPrefix("> ") || cur == ">" { break }
			if cur.hasPrefix("- ") || cur.hasPrefix("* ") || cur.hasPrefix("+ ") { break }
			// Ordered list check
			if let sp = cur.firstIndex(of: " "),
			   cur[..<sp].hasSuffix("."),
			   Int(String(cur[..<cur.index(before: sp)])) != nil { break }
			// Horizontal rule check
			if !curTrimmed.isEmpty,
			   curTrimmed.allSatisfy({ $0 == "-" || $0 == " " }),
			   curTrimmed.filter({ $0 == "-" }).count >= 3 { break }
			paraLines.append(cur)
			i += 1
		}
		if !paraLines.isEmpty {
			let text = paraLines.map { inlineToHTML($0) }.joined(separator: "\n")
			out += "<p>\(text)</p>\n"
		}
	}

	closeLists()
	// Close any unclosed code block
	if inCode {
		let escaped = codeAccum.map { htmlEscape($0) }.joined(separator: "\n")
		out += "<pre><code>\(escaped)</code></pre>\n"
	}
	return out
}

/// Processes inline Markdown spans within a single line of text.
private func inlineToHTML(_ text: String) -> String {
	// Start by HTML-escaping the raw text, then selectively restore markdown spans.
	// We process spans manually on the unescaped text to avoid escaping inside tags.
	var s = text

	// Images before links (so ![...](...) isn't parsed as a link first)
	s = s.replacingOccurrences(
		of: #"!\[([^\]]*)\]\(([^)]+)\)"#,
		with: #"<img src="\#(htmlEscape("$2"))" alt="\#(htmlEscape("$1"))">"#,
		options: .regularExpression
	)
	// Actually the replacingOccurrences regex doesn't run htmlEscape on captures —
	// use a two-pass approach instead.
	s = applyInlinePatterns(s)
	return s
}

private func applyInlinePatterns(_ input: String) -> String {
	// We escape first, then apply patterns on escaped text.
	// This means regex backreferences contain already-escaped text, which is fine
	// for attribute values and element content.
	var s = htmlEscape(input)

	// Images: ![alt](url)  — already html-escaped
	s = s.replacingOccurrences(
		of: #"!\[([^\]]*)\]\(([^)]+)\)"#,
		with: #"<img src="$2" alt="$1">"#,
		options: .regularExpression
	)
	// Links: [text](url)
	s = s.replacingOccurrences(
		of: #"\[([^\]]+)\]\(([^)]+)\)"#,
		with: #"<a href="$2">$1</a>"#,
		options: .regularExpression
	)
	// Bold+italic: ***…***
	s = s.replacingOccurrences(
		of: #"\*\*\*(.+?)\*\*\*"#,
		with: "<strong><em>$1</em></strong>",
		options: .regularExpression
	)
	// Bold: **…**
	s = s.replacingOccurrences(
		of: #"\*\*(.+?)\*\*"#,
		with: "<strong>$1</strong>",
		options: .regularExpression
	)
	// Bold: __…__
	s = s.replacingOccurrences(
		of: #"__(.+?)__"#,
		with: "<strong>$1</strong>",
		options: .regularExpression
	)
	// Italic: *…*
	s = s.replacingOccurrences(
		of: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#,
		with: "<em>$1</em>",
		options: .regularExpression
	)
	// Italic: _…_
	s = s.replacingOccurrences(
		of: #"(?<![_])_([^_]+)_(?![_])"#,
		with: "<em>$1</em>",
		options: .regularExpression
	)
	// Strikethrough: ~~…~~
	s = s.replacingOccurrences(
		of: #"~~(.+?)~~"#,
		with: "<del>$1</del>",
		options: .regularExpression
	)
	// Inline code: `…`
	s = s.replacingOccurrences(
		of: #"`([^`]+)`"#,
		with: "<code>$1</code>",
		options: .regularExpression
	)

	return s
}

private func htmlEscape(_ text: String) -> String {
	text
		.replacingOccurrences(of: "&",  with: "&amp;")
		.replacingOccurrences(of: "<",  with: "&lt;")
		.replacingOccurrences(of: ">",  with: "&gt;")
		.replacingOccurrences(of: "\"", with: "&quot;")
}

// MARK: - EML → HTML

/// Extracts the HTML body from an EML (MIME) email file.
/// Handles `multipart/*` with nested parts, base64, and quoted-printable encoding.
func extractHTMLFromEML(_ content: String) -> String? {
	let text = content
		.replacingOccurrences(of: "\r\n", with: "\n")
		.replacingOccurrences(of: "\r",   with: "\n")

	let (topHeaders, _) = mimeHeadersAndBody(text)
	let contentType = topHeaders["content-type"] ?? ""

	if contentType.lowercased().contains("multipart"),
	   let boundary = mimeBoundary(from: contentType) {
		let parts = mimeParts(of: text, boundary: boundary)
		// Direct text/html part
		for part in parts {
			let (h, body) = mimeHeadersAndBody(part)
			let ct = h["content-type"] ?? ""
			if ct.lowercased().contains("text/html") {
				let enc = (h["content-transfer-encoding"] ?? "").lowercased()
				return decodeMIMEBody(body, encoding: enc)
			}
		}
		// Nested multipart
		for part in parts {
			let (h, body) = mimeHeadersAndBody(part)
			let ct = h["content-type"] ?? ""
			if ct.lowercased().contains("multipart"),
			   let nested = extractHTMLFromEML(body) {
				return nested
			}
		}
	} else if contentType.lowercased().contains("text/html") {
		let (_, body) = mimeHeadersAndBody(text)
		let enc = (topHeaders["content-transfer-encoding"] ?? "").lowercased()
		return decodeMIMEBody(body, encoding: enc)
	}

	// Fallback: scan for <html
	if let range = text.range(of: "<html", options: .caseInsensitive) {
		return String(text[range.lowerBound...])
	}
	return nil
}

// MARK: - MIME helpers

/// Parses MIME headers from the top of `text`.
/// Returns a dictionary of lowercased header names → values, and the body string.
private func mimeHeadersAndBody(_ text: String) -> ([String: String], String) {
	var headers: [String: String] = [:]
	let lines = text.components(separatedBy: "\n")
	var bodyStart = lines.endIndex
	var lastKey: String? = nil

	for (idx, line) in lines.enumerated() {
		if line.trimmingCharacters(in: .whitespaces).isEmpty {
			bodyStart = idx + 1
			break
		}
		// Folded header continuation
		if line.hasPrefix("\t") || line.hasPrefix(" "), let key = lastKey {
			headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
			continue
		}
		if let colonIdx = line.firstIndex(of: ":") {
			let key   = String(line[..<colonIdx]).lowercased().trimmingCharacters(in: .whitespaces)
			let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
			headers[key] = value
			lastKey = key
		}
	}

	let body: String
	if bodyStart < lines.endIndex {
		body = lines[bodyStart...].joined(separator: "\n")
	} else {
		body = ""
	}
	return (headers, body)
}

/// Extracts the MIME boundary value from a Content-Type header.
private func mimeBoundary(from contentType: String) -> String? {
	for part in contentType.components(separatedBy: ";") {
		let t = part.trimmingCharacters(in: .whitespaces)
		if t.lowercased().hasPrefix("boundary=") {
			var v = String(t.dropFirst("boundary=".count))
			if v.hasPrefix("\"") && v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
			return v
		}
	}
	return nil
}

/// Splits a MIME body into parts using the given boundary string.
private func mimeParts(of text: String, boundary: String) -> [String] {
	let delim = "--" + boundary
	let end   = "--" + boundary + "--"
	var parts: [String] = []
	var current: [String] = []
	var inside = false

	for line in text.components(separatedBy: "\n") {
		let s = line.trimmingCharacters(in: .whitespaces)
		if s == end { break }
		if s == delim {
			if inside { parts.append(current.joined(separator: "\n")) }
			current = []; inside = true; continue
		}
		if inside { current.append(line) }
	}
	if inside, !current.isEmpty { parts.append(current.joined(separator: "\n")) }
	return parts
}

/// Decodes a MIME body according to its Content-Transfer-Encoding.
private func decodeMIMEBody(_ body: String, encoding: String) -> String {
	switch encoding {
	case "base64":
		let compact = body.components(separatedBy: .whitespacesAndNewlines).joined()
		if let data = Data(base64Encoded: compact),
		   let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
			return s
		}
		return body
	case "quoted-printable":
		return decodeQuotedPrintable(body)
	default:
		return body
	}
}

/// Minimal quoted-printable decoder.
private func decodeQuotedPrintable(_ text: String) -> String {
	var result = ""
	var i = text.startIndex
	while i < text.endIndex {
		let ch = text[i]
		if ch == "=" {
			let j = text.index(after: i)
			if j < text.endIndex, text[j] == "\n" {
				// Soft line break
				i = text.index(after: j); continue
			}
			if let k = text.index(j, offsetBy: 2, limitedBy: text.endIndex),
			   let byte = UInt8(String(text[j..<k]), radix: 16) {
				result.append(Character(UnicodeScalar(byte)))
				i = k; continue
			}
		}
		result.append(ch)
		i = text.index(after: i)
	}
	return result
}

#endif
