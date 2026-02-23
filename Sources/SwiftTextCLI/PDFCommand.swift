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

private let responsiveMarkdownImageClass = "swifttext-markdown-image"
private let responsiveMarkdownImageInlineStyle = "display: block; width: 100%; max-width: 100%; height: auto;"

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
	h1, h2, h3, h4, h5, h6 {
	    font-weight: 600;
	    margin: 1.2em 0 0.4em;
	    line-height: 1.3;
	    page-break-after: avoid;
	    break-after: avoid;
	    page-break-inside: avoid;
	    break-inside: avoid;
	}
	/* H1, H2: Start major sections on new page */
	h1, h2 {
	    page-break-before: always;
	    break-before: always;
	}
	/* H3 immediately after H2: also break (keep h2+h3 group together on new page) */
	h2 + h3 {
	    page-break-before: always;
	    break-before: always;
	}
	/* First heading: Don't force page break */
	section:first-of-type > h1:first-child,
	section:first-of-type > h2:first-child {
	    page-break-before: auto;
	    break-before: auto;
	}
	/* Subsection headings: avoid breaking away from parent context */
	h3, h4, h5, h6 {
	    page-break-before: avoid;
	    break-before: avoid;
	}
	h1 { font-size: 2em;    border-bottom: 2px solid #ddd; padding-bottom: 0.2em; }
	h2 { font-size: 1.5em;  border-bottom: 1px solid #eee; padding-bottom: 0.1em; }
	h3 { font-size: 1.25em; }
	/* Semantic sections (heading + content until next heading) */
	section {
	    page-break-inside: avoid;
	    break-inside: avoid;
	}
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
	table { border-collapse: collapse; width: 100%; margin: 0.8em 0; font-size: 0.95em; }
	th, td { border: 1px solid #ccc; padding: 0.4em 0.7em; text-align: left; }
	th { background: #f0f0f0; font-weight: 600; }
	tr:nth-child(even) td { background: #fafafa; }
	img.\(responsiveMarkdownImageClass) {
	    \(responsiveMarkdownImageInlineStyle)
	    page-break-before: avoid;
	    break-before: avoid;
	    page-break-inside: avoid;
	    break-inside: avoid;
	}
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

/// Converts the body of a Markdown document to HTML.
/// Handles: headings, fenced code blocks, blockquotes, unordered/ordered lists,
/// horizontal rules, bold, italic, inline code, links, images, footnotes, and paragraphs.
private func convertMarkdownBody(_ markdown: String) -> String {
	let footnoteState = FootnoteRenderState()
	footnoteState.beginCollectionPass()
	_ = convertMarkdownBody(markdown, footnoteState: footnoteState)
	footnoteState.beginRenderPass()
	return convertMarkdownBody(markdown, footnoteState: footnoteState)
}

private func convertMarkdownBody(_ markdown: String, footnoteState: FootnoteRenderState) -> String {
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
	var openSectionLevels: [Int] = []  // Stack of open section heading levels

	// Flush any open list tags
	func closeLists() {
		if inUL { out += "</ul>\n"; inUL = false }
		if inOL { out += "</ol>\n"; inOL = false }
	}
	
	// Close sections at this level or higher
	func closeSectionsAtLevel(_ level: Int) {
		while let lastLevel = openSectionLevels.last, lastLevel >= level {
			out += "</section>\n"
			openSectionLevels.removeLast()
		}
	}
	
	// Close all open sections
	func closeAllSections() {
		while !openSectionLevels.isEmpty {
			out += "</section>\n"
			openSectionLevels.removeLast()
		}
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
				closeAllSections()
				inCode = true
				codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
			}
			i += 1; continue
		}
		if inCode { codeAccum.append(line); i += 1; continue }

		// ── Footnote definition ([^id]: ...) ──────────────────────────
		if let definitionStart = parseFootnoteDefinitionStart(line) {
			closeLists()
			closeAllSections()
			let definition = parseFootnoteDefinition(
				lines: lines,
				startIndex: i,
				definitionStart: definitionStart
			)
			let number = footnoteState.number(for: definition.identifier)
			out += renderFootnoteDefinition(
				number: number,
				contentLines: definition.contentLines,
				footnoteState: footnoteState
			)
			out += "\n"
			i = definition.nextIndex
			continue
		}

		// ── ATX headings (#…) ─────────────────────────────────────────
		if line.hasPrefix("#") {
			var level = 0
			for ch in line { guard ch == "#" else { break }; level += 1 }
			if level <= 6, line.count > level, line[line.index(line.startIndex, offsetBy: level)] == " " {
				closeLists()
				closeSectionsAtLevel(level)
				let text = String(line.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
				out += "<section>\n"
				out += "<h\(level)>\(inlineToHTML(text, footnoteState: footnoteState))</h\(level)>\n"
				openSectionLevels.append(level)
				i += 1; continue
			}
		}

		// ── Horizontal rule (---, ***, ___) ──────────────────────────
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		if !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "-" || $0 == " " }),
		   trimmed.filter({ $0 == "-" }).count >= 3 {
			closeLists()
			closeAllSections()
			out += "<hr>\n"
			i += 1; continue
		}
		if trimmed == "***" || trimmed == "___" {
			closeLists()
			closeAllSections()
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
			let inner = convertMarkdownBody(qLines.joined(separator: "\n"), footnoteState: footnoteState)
			out += "<blockquote>\n\(inner)</blockquote>\n"
			continue
		}

		// ── Unordered list (- / * / +) ────────────────────────────────
		if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
			if inOL { out += "</ol>\n"; inOL = false }
			if !inUL {
				out += "<ul>\n"
				inUL = true
			}
			let text = String(line.dropFirst(2))
			
			// Check for nested list items (indented with 4 spaces or 1 tab)
			var nestedLines: [String] = []
			var j = i + 1
			while j < lines.count {
				let nextLine = lines[j]
				// Match 4-space or 1-tab indented list items
				if nextLine.hasPrefix("    -") || nextLine.hasPrefix("    *") || nextLine.hasPrefix("    +") ||
				   nextLine.hasPrefix("\t-") || nextLine.hasPrefix("\t*") || nextLine.hasPrefix("\t+") {
					// Strip 4 spaces or 1 tab
					let stripped = nextLine.hasPrefix("\t") ? String(nextLine.dropFirst()) : String(nextLine.dropFirst(4))
					nestedLines.append(stripped)
					j += 1
				} else if nextLine.trimmingCharacters(in: .whitespaces).isEmpty {
					// Include blank lines in nested content
					nestedLines.append("")
					j += 1
				} else {
					// Non-nested content, stop collecting
					break
				}
			}
			
			if nestedLines.isEmpty {
				out += "<li>\(inlineToHTML(text, footnoteState: footnoteState))</li>\n"
			} else {
				// Render item with nested list
				let nested = convertMarkdownBody(nestedLines.joined(separator: "\n"), footnoteState: footnoteState)
				out += "<li>\(inlineToHTML(text, footnoteState: footnoteState))\n\(nested)</li>\n"
				i = j
				continue
			}
			
			i += 1; continue
		}

		// ── Ordered list (1. 2. …) ───────────────────────────────────
		if let spaceIdx = line.firstIndex(of: " "),
		   line[..<spaceIdx].hasSuffix("."),
		   let _ = Int(String(line[..<line.index(before: spaceIdx)])) {
			if inUL { out += "</ul>\n"; inUL = false }
			if !inOL {
				out += "<ol>\n"
				inOL = true
			}
			let text = String(line[line.index(after: spaceIdx)...])
			out += "<li>\(inlineToHTML(text, footnoteState: footnoteState))</li>\n"
			i += 1; continue
		}

		// ── Blank line ────────────────────────────────────────────────
		if trimmed.isEmpty {
			closeLists()
			// Don't close heading group on blank lines (allows spacing)
			out += "\n"
			i += 1; continue
		}

		// ── Orphaned indented bullets (not nested) ────────────────────
		// Treat 4-space indented bullets at top level as de-indented bullets
		if line.hasPrefix("    -") || line.hasPrefix("    *") || line.hasPrefix("    +") ||
		   line.hasPrefix("\t-") || line.hasPrefix("\t*") || line.hasPrefix("\t+") {
			if inOL { out += "</ol>\n"; inOL = false }
			if !inUL { out += "<ul>\n"; inUL = true }
			let stripped = line.hasPrefix("\t") ? String(line.dropFirst()) : String(line.dropFirst(4))
			let text = String(stripped.dropFirst(2))
			out += "<li>\(inlineToHTML(text, footnoteState: footnoteState))</li>\n"
			i += 1; continue
		}

		// ── Plain paragraph ───────────────────────────────────────────
		closeLists()
		var paraLines: [String] = []
		while i < lines.count {
			let cur = lines[i]
			let curTrimmed = cur.trimmingCharacters(in: .whitespaces)
			if curTrimmed.isEmpty { break }
			if parseFootnoteDefinitionStart(cur) != nil { break }
			if cur.hasPrefix("#") || cur.hasPrefix("```") { break }
			if cur.hasPrefix("> ") || cur == ">" { break }
			if cur.hasPrefix("- ") || cur.hasPrefix("* ") || cur.hasPrefix("+ ") { break }
			// Indented list items (nested)
			if cur.hasPrefix("    -") || cur.hasPrefix("    *") || cur.hasPrefix("    +") { break }
			if cur.hasPrefix("\t-") || cur.hasPrefix("\t*") || cur.hasPrefix("\t+") { break }
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
				let text = paraLines.map { inlineToHTML($0, footnoteState: footnoteState) }.joined(separator: "\n")
				out += "<p>\(text)</p>\n"
			}
		}

	closeLists()
	closeAllSections()
	// Close any unclosed code block
	if inCode {
		let escaped = codeAccum.map { htmlEscape($0) }.joined(separator: "\n")
		out += "<pre><code>\(escaped)</code></pre>\n"
	}
	return out
}

private struct FootnoteDefinitionBlock {
	let identifier: String
	let contentLines: [String]
	let nextIndex: Int
}

private final class FootnoteRenderState {
	private var numberByIdentifier: [String: Int] = [:]
	private var nextNumber = 1
	private var referenceCountByNumber: [Int: Int] = [:]
	private var renderedReferenceCountByNumber: [Int: Int] = [:]
	private var collectingReferences = false

	func beginCollectionPass() {
		numberByIdentifier.removeAll(keepingCapacity: true)
		nextNumber = 1
		referenceCountByNumber.removeAll(keepingCapacity: true)
		renderedReferenceCountByNumber.removeAll(keepingCapacity: true)
		collectingReferences = true
	}

	func beginRenderPass() {
		renderedReferenceCountByNumber.removeAll(keepingCapacity: true)
		collectingReferences = false
	}

	func number(for identifier: String) -> Int {
		if let existing = numberByIdentifier[identifier] {
			return existing
		}
		let assigned = nextNumber
		numberByIdentifier[identifier] = assigned
		nextNumber += 1
		return assigned
	}

	func replacementHTMLForReference(identifier: String) -> String {
		let number = number(for: identifier)

		if collectingReferences {
			referenceCountByNumber[number, default: 0] += 1
			return "[^\(identifier)]"
		}

		let referenceID = nextReferenceAnchorID(for: number)
		return "<sup><a href=\"#fn-\(number)\" id=\"\(referenceID)\">[\(number)]</a></sup>"
	}

	func nextReferenceAnchorID(for number: Int) -> String {
		let count = (renderedReferenceCountByNumber[number] ?? 0) + 1
		renderedReferenceCountByNumber[number] = count
		return count == 1 ? primaryReferenceAnchorID(for: number) : "\(primaryReferenceAnchorID(for: number))-\(count)"
	}

	func backlinkHTML(for number: Int) -> String? {
		guard referenceCountByNumber[number] == 1 else { return nil }
		return "<a href=\"#\(primaryReferenceAnchorID(for: number))\">↩</a>"
	}

	func primaryReferenceAnchorID(for number: Int) -> String {
		"ref-\(number)"
	}
}

private func parseFootnoteDefinitionStart(_ line: String) -> (identifier: String, content: String)? {
	guard line.hasPrefix("[^"),
	      let closingBracket = line.firstIndex(of: "]") else { return nil }
	let identifierStart = line.index(line.startIndex, offsetBy: 2)
	guard identifierStart < closingBracket else { return nil }
	let colonIndex = line.index(after: closingBracket)
	guard colonIndex < line.endIndex, line[colonIndex] == ":" else { return nil }

	let identifier = String(line[identifierStart..<closingBracket]).trimmingCharacters(in: .whitespaces)
	guard !identifier.isEmpty else { return nil }

	let contentStart = line.index(after: colonIndex)
	let content = contentStart < line.endIndex
		? String(line[contentStart...]).trimmingCharacters(in: .whitespaces)
		: ""
	return (identifier, content)
}

private func parseFootnoteDefinition(
	lines: [String],
	startIndex: Int,
	definitionStart: (identifier: String, content: String)
) -> FootnoteDefinitionBlock {
	var contentLines: [String] = []
	if !definitionStart.content.isEmpty {
		contentLines.append(definitionStart.content)
	}

	var i = startIndex + 1
	while i < lines.count {
		let line = lines[i]

		if let continuation = stripFootnoteContinuationIndent(from: line) {
			contentLines.append(continuation)
			i += 1
			continue
		}

		if line.trimmingCharacters(in: .whitespaces).isEmpty {
			var lookahead = i + 1
			while lookahead < lines.count && lines[lookahead].trimmingCharacters(in: .whitespaces).isEmpty {
				lookahead += 1
			}

			if lookahead < lines.count, stripFootnoteContinuationIndent(from: lines[lookahead]) != nil {
				contentLines.append("")
				i += 1
				continue
			}
		}

		break
	}

	return FootnoteDefinitionBlock(
		identifier: definitionStart.identifier,
		contentLines: contentLines,
		nextIndex: i
	)
}

private func stripFootnoteContinuationIndent(from line: String) -> String? {
	if line.hasPrefix("\t") {
		return String(line.dropFirst())
	}
	guard line.hasPrefix("    ") else { return nil }
	return String(line.dropFirst(4))
}

private func renderFootnoteDefinition(
	number: Int,
	contentLines: [String],
	footnoteState: FootnoteRenderState
) -> String {
	let paragraphs = splitFootnoteParagraphs(contentLines)
	let backlink = footnoteState.backlinkHTML(for: number)

	if paragraphs.isEmpty {
		let suffix = backlink.map { " \($0)" } ?? ""
		return """
		<div class="footnote-definition" id="fn-\(number)">
		<strong>[\(number)]:</strong>\(suffix)
		</div>
		"""
	}

	if paragraphs.count == 1 {
		let content = paragraphs[0]
			.map { inlineToHTML($0, footnoteState: footnoteState) }
			.joined(separator: "<br>\n")
		let suffix = backlink.map { " \($0)" } ?? ""
		return """
		<div class="footnote-definition" id="fn-\(number)">
		<strong>[\(number)]:</strong> \(content)\(suffix)
		</div>
		"""
	}

	var renderedParagraphs: [String] = []
	for (index, lines) in paragraphs.enumerated() {
		let content = lines
			.map { inlineToHTML($0, footnoteState: footnoteState) }
			.joined(separator: "<br>\n")
		if index == 0 {
			renderedParagraphs.append("<p><strong>[\(number)]:</strong> \(content)</p>")
		} else if index == paragraphs.count - 1, let backlink {
			renderedParagraphs.append("<p>\(content) \(backlink)</p>")
		} else if index == paragraphs.count - 1 {
			renderedParagraphs.append("<p>\(content)</p>")
		} else {
			renderedParagraphs.append("<p>\(content)</p>")
		}
	}

	return """
	<div class="footnote-definition" id="fn-\(number)">
	\(renderedParagraphs.joined(separator: "\n"))
	</div>
	"""
}

private func splitFootnoteParagraphs(_ lines: [String]) -> [[String]] {
	var paragraphs: [[String]] = []
	var current: [String] = []

	for line in lines {
		if line.trimmingCharacters(in: .whitespaces).isEmpty {
			if !current.isEmpty {
				paragraphs.append(current)
				current = []
			}
			continue
		}
		current.append(line)
	}

	if !current.isEmpty {
		paragraphs.append(current)
	}

	return paragraphs
}

/// Processes inline Markdown spans within a single line of text.
private func inlineToHTML(_ text: String, footnoteState: FootnoteRenderState) -> String {
	applyInlinePatterns(text, footnoteState: footnoteState)
}

private func applyInlinePatterns(_ input: String, footnoteState: FootnoteRenderState) -> String {
	// We escape first, then apply patterns on escaped text.
	// This means regex backreferences contain already-escaped text, which is fine
	// for attribute values and element content.
	var s = htmlEscape(input)

	// Images: ![alt](url)  — already html-escaped
	s = s.replacingOccurrences(
		of: #"!\[([^\]]*)\]\(([^)]+)\)"#,
		with: #"<img src="$2" alt="$1" class="\#(responsiveMarkdownImageClass)" style="\#(responsiveMarkdownImageInlineStyle)">"#,
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

	s = renderInlineFootnoteReferences(in: s, footnoteState: footnoteState)

	return s
}

private func renderInlineFootnoteReferences(in text: String, footnoteState: FootnoteRenderState) -> String {
	guard let regex = try? NSRegularExpression(pattern: #"\[\^([^\]]+)\]"#) else {
		return text
	}
	let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
	let matches = regex.matches(in: text, range: fullRange)
	guard !matches.isEmpty else {
		return text
	}

	let nsText = text as NSString
	var rendered = ""
	var currentIndex = 0

	for match in matches {
		let range = match.range
		let identifierRange = match.range(at: 1)
		guard range.location >= currentIndex else { continue }
		rendered += nsText.substring(with: NSRange(location: currentIndex, length: range.location - currentIndex))

		let identifier = nsText.substring(with: identifierRange)
		rendered += footnoteState.replacementHTMLForReference(identifier: identifier)

		currentIndex = range.location + range.length
	}

	rendered += nsText.substring(from: currentIndex)
	return rendered
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
