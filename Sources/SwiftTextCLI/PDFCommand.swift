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
import WebKit

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
		let htmlSource = try convertToHTML(fileURL: fileURL)
		let outputURL = fileOutputURL(from: fileURL)
		try await render(htmlSource, to: outputURL)
		print(outputURL.path)
	}

	// MARK: - Input → HTML conversion

	enum HTMLSource {
		case string(String, baseURL: URL?)
		case file(URL, readAccessRoot: URL)
	}

	/// Converts a file at the given URL to an HTML source.
	/// For markdown/docx, writes HTML to a temp file to enable local image access via loadFileURL.
	func convertToHTML(fileURL: URL) throws -> HTMLSource {
		let ext = fileURL.pathExtension.lowercased()
		let baseURL = fileURL.deletingLastPathComponent()

		switch ext {
		case "html", "htm":
			// Native HTML files can be loaded directly
			return .file(fileURL, readAccessRoot: baseURL)

		case "md", "markdown", "docx":
			let html: String
			if ext == "docx" {
				let docx = try DocxFile(url: fileURL)
				let md = docx.markdown()
				html = markdownToHTML(md, paper: paper, landscape: landscape)
			} else {
				let md = try String(contentsOf: fileURL, encoding: .utf8)
				html = markdownToHTML(md, paper: paper, landscape: landscape)
			}
			
			// Write HTML to temp file in source directory (enables local image access)
			let tempHTML = baseURL.appendingPathComponent(".\(UUID().uuidString).html")
			try html.write(to: tempHTML, atomically: true, encoding: .utf8)
			return .file(tempHTML, readAccessRoot: baseURL)

		case "eml":
			let raw = try String(contentsOf: fileURL, encoding: .utf8)
			guard let extracted = extractHTMLFromEML(raw) else {
				throw ValidationError("No HTML body found in EML file: \(fileURL.lastPathComponent)")
			}
			return .string(extracted, baseURL: nil)

		default:
			throw ValidationError(
				"Unsupported file type '.\(ext)'. Supported: html, htm, md, markdown, docx, eml."
			)
		}
	}

	// MARK: - WebKit rendering

	/// Builds a `WKPDFConfiguration` whose rect matches the chosen paper size and orientation.
	@MainActor
	@available(macOS 12.0, *)
	private func pdfConfiguration() -> WKPDFConfiguration {
		let config = WKPDFConfiguration()
		let size = paper.pointSize
		if landscape {
			config.rect = CGRect(origin: .zero, size: CGSize(width: size.height, height: size.width))
		} else {
			config.rect = CGRect(origin: .zero, size: size)
		}
		return config
	}

	/// Renders an HTMLSource to a PDF file using WebKit.
	@MainActor
	@available(macOS 12.0, *)
	private func render(_ source: HTMLSource, to outputURL: URL) async throws {
		var tempFileToCleanup: URL? = nil
		defer {
			if let temp = tempFileToCleanup {
				try? FileManager.default.removeItem(at: temp)
			}
		}

		let browser: WebKitBrowser
		switch source {
		case .string(let html, let baseURL):
			browser = WebKitBrowser(htmlString: html, baseURL: baseURL)
		case .file(let fileURL, let readAccessRoot):
			browser = WebKitBrowser(fileURL: fileURL, readAccessRoot: readAccessRoot)
			// Mark temp file for cleanup if it's hidden
			if fileURL.lastPathComponent.hasPrefix(".") {
				tempFileToCleanup = fileURL
			}
		}

		browser.frameSize = pageSize()
		browser.preserveFrameHeight = true
		await browser.waitForLoadCompletion()
		let pdfData = try await browser.exportPaginatedPDFData(paperSize: pageSize())
		try writeData(pdfData, to: outputURL)
	}

	/// Renders an HTML string to a PDF file using WebKit.
	@MainActor
	@available(macOS 12.0, *)
	private func renderHTML(_ html: String, sourceURL: URL?, to outputURL: URL) async throws {
		let browser = WebKitBrowser(htmlString: html, baseURL: sourceURL)
		browser.frameSize = pageSize()
		browser.preserveFrameHeight = true
		await browser.waitForLoadCompletion()
		let pdfData = try await browser.exportPaginatedPDFData(paperSize: pageSize())
		try writeData(pdfData, to: outputURL)
	}

	/// Loads a URL in WebKit and renders the result to a PDF file.
	@MainActor
	@available(macOS 12.0, *)
	private func renderURL(_ url: URL, to outputURL: URL) async throws {
		let browser = WebKitBrowser(url: url)
		browser.frameSize = pageSize()
		browser.preserveFrameHeight = true
		await browser.waitForLoadCompletion()
		let pdfData = try await browser.exportPaginatedPDFData(paperSize: pageSize())
		try writeData(pdfData, to: outputURL)
	}

	/// Returns the page size in points, respecting orientation.
	private func pageSize() -> CGSize {
		let size = paper.pointSize
		if landscape {
			return CGSize(width: size.height, height: size.width)
		}
		return size
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
func markdownToHTML(_ markdown: String, paper: PaperSize, landscape: Bool) -> String {
	let orientation = landscape ? "landscape" : "portrait"
	let pageCSS = "\(paper.cssName) \(orientation)"
	let body = MarkdownToHTML.convert(markdown)
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
	    max-width: 960px;
	    margin: 0 auto;
	    padding: 2em;
	}
	@media print {
	    body { max-width: none; padding: 0; margin: 0; }
	}
	h1, h2, h3, h4, h5, h6 {
	    font-weight: 600;
	    margin: 1.2em 0 0.4em;
	    line-height: 1.3;
	    page-break-after: avoid;
	    break-after: avoid;
	    page-break-inside: avoid;
	    break-inside: avoid;
	}
	h1 { font-size: 2em;    border-bottom: 2px solid #ddd; padding-bottom: 0.2em; }
	h2 { font-size: 1.5em;  border-bottom: 1px solid #eee; padding-bottom: 0.1em; }
	h3 { font-size: 1.25em; }
	p  {
	    margin: 0.6em 0;
	    orphans: 2;
	    widows: 2;
	}
	ul, ol {
	    margin: 0.6em 0;
	    padding-left: 1.8em;
	}
	li {
	    margin: 0.2em 0;
	    orphans: 2;
	    widows: 2;
	    page-break-inside: avoid;
	    break-inside: avoid;
	}
	blockquote {
	    border-left: 4px solid #ccc;
	    padding: 0.3em 1em;
	    margin: 0.6em 0;
	    color: #555;
	}
	.markdown-alert {
	    border-left-width: 4px;
	    border-left-style: solid;
	    border-radius: 6px;
	    margin: 0.8em 0;
	    padding: 0.75em 1em;
	    page-break-inside: avoid;
	    break-inside: avoid;
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
	    padding: 0.8em;
	    margin: 0.8em 0;
	    overflow: hidden;
	    line-height: 1.2;
	    box-sizing: border-box;
	    max-width: calc(100% - 2em);
	    font-size: 10pt;
	    white-space: pre-wrap;
	    word-break: break-all;
	    contain: layout;
	    page-break-inside: avoid;
	    break-inside: avoid;
	}
	pre code {
	    background: none;
	    border: none;
	    padding: 0;
	    font-size: inherit;
	    line-height: 1.2;
	    white-space: pre-wrap;
	    word-break: break-all;
	}
	table { border-collapse: collapse; margin: 0.8em 0; font-size: 0.95em; }
	th, td { border: 1px solid #999; padding: 0.4em 0.7em; text-align: left; }
	th { background: #dcdcdc; font-weight: 600; }
	tr:nth-child(even) td { background: #f9f9f9; }
	img {
	    display: block;
	    max-width: 100%;
	    height: auto;
	    page-break-before: avoid;
	    break-before: avoid;
	    page-break-inside: avoid;
	    break-inside: avoid;
	}
	@media print {
	    img { width: 100%; max-width: 100%; }
	}
	/* GFM task list checkboxes from swift-markdown */
	li.task-list-item { list-style: none; margin-left: -1.2em; }
	li.task-list-item input[type="checkbox"] { margin-right: 0.4em; vertical-align: middle; }
	del { color: #777; }
	hr { border: none; border-top: 1px solid #ddd; margin: 1.2em 0; }
	a { color: #0366d6; }
	sup a { text-decoration: none; }
	.footnote-definition {
	    margin: 0.8em 0;
	    font-size: 0.95em;
	}
	.footnote-definition p { margin: 0.4em 0; }
	</style>
	</head>
	<body>
	\(body)
	</body>
	</html>
	"""
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
