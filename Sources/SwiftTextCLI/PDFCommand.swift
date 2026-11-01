//
//  PDFCommand.swift
//  SwiftText
//
//  Created by Oliver Drobnik on 18.02.26.
//

import ArgumentParser
import Foundation
import SwiftTextMarkdown
import SwiftTextHTML
import SwiftTextDOCX
import SwiftTextRender
#if os(macOS)
import WebKit
#endif

// MARK: - Render engine

/// Which engine renders the PDF.
enum RenderEngine: String, ExpressibleByArgument, CaseIterable {
	/// WebKit + NSPrintOperation (macOS only, full CSS).
	case webkit
	/// The cross-platform SwiftTextRender engine (no WebKit).
	case swift

	/// The default engine for the current platform: WebKit on macOS (full CSS
	/// fidelity), the pure-Swift SwiftTextRender engine everywhere else — WebKit
	/// isn't available off macOS.
	static var platformDefault: RenderEngine {
		#if os(macOS)
		return .webkit
		#else
		return .swift
		#endif
	}
}

// MARK: - Paper size

/// Page dimensions in PDF points (1/72"), portrait orientation. A pure-Swift
/// value type, so paper sizing works without CoreGraphics' `CGSize` (Apple-only).
struct PagePoints {
	var width: Double
	var height: Double
}

enum PaperSize: String, ExpressibleByArgument, CaseIterable {
	case a4
	case letter

	/// Page dimensions in points (portrait orientation).
	var pointSize: PagePoints {
		switch self {
		case .a4:     return PagePoints(width: 595.28, height: 841.89)
		case .letter: return PagePoints(width: 612.0, height: 792.0)
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
		abstract: "Render an HTML, Markdown, DOCX, or EML file (or URL) to PDF."
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

	@Option(name: .long, help: "Rendering engine: webkit (macOS only, full CSS) or swift (cross-platform, no WebKit). Defaults to webkit on macOS, swift elsewhere.")
	var engine: RenderEngine = .platformDefault

	// MARK: - Run

	func run() async throws {
		#if os(macOS)
		guard #available(macOS 12.0, *) else {
			throw ValidationError("The pdf command requires macOS 12 or newer.")
		}
		#else
		if engine == .webkit {
			throw ValidationError("The webkit engine is only available on macOS; use --engine swift.")
		}
		#endif

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
			let raw = try Data(contentsOf: fileURL)
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

	// MARK: - Rendering

	/// Renders an HTMLSource to a PDF file (swift engine everywhere; WebKit on macOS).
	@MainActor
	@available(macOS 12.0, *)
	private func render(_ source: HTMLSource, to outputURL: URL) async throws {
		if engine == .swift {
			let (html, baseURL) = try htmlString(from: source)
			try await renderSwift(html: html, baseURL: baseURL, to: outputURL)
			return
		}
		#if os(macOS)
		var tempFileToCleanup: URL?
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
		#else
		throw ValidationError("The webkit engine is only available on macOS; use --engine swift.")
		#endif
	}

	/// Renders an HTML string to a PDF file (swift engine everywhere; WebKit on macOS).
	@MainActor
	@available(macOS 12.0, *)
	private func renderHTML(_ html: String, sourceURL: URL?, to outputURL: URL) async throws {
		if engine == .swift {
			try await renderSwift(html: html, baseURL: sourceURL, to: outputURL)
			return
		}
		#if os(macOS)
		let browser = WebKitBrowser(htmlString: html, baseURL: sourceURL)
		browser.frameSize = pageSize()
		browser.preserveFrameHeight = true
		await browser.waitForLoadCompletion()
		let pdfData = try await browser.exportPaginatedPDFData(paperSize: pageSize())
		try writeData(pdfData, to: outputURL)
		#else
		throw ValidationError("The webkit engine is only available on macOS; use --engine swift.")
		#endif
	}

	/// Loads an http(s) URL and renders the result to a PDF file. WebKit only —
	/// the swift engine can't fetch/execute pages.
	@MainActor
	@available(macOS 12.0, *)
	private func renderURL(_ url: URL, to outputURL: URL) async throws {
		if engine == .swift {
			throw ValidationError("--engine swift cannot load http(s) URLs; save the page to an .html file first.")
		}
		#if os(macOS)
		let browser = WebKitBrowser(url: url)
		browser.frameSize = pageSize()
		browser.preserveFrameHeight = true
		await browser.waitForLoadCompletion()
		let pdfData = try await browser.exportPaginatedPDFData(paperSize: pageSize())
		try writeData(pdfData, to: outputURL)
		#else
		throw ValidationError("The webkit engine is only available on macOS; use --engine swift.")
		#endif
	}

	/// Renders HTML to a PDF file using the cross-platform SwiftTextRender engine.
	@available(macOS 12.0, *)
	private func renderSwift(html: String, baseURL: URL?, to outputURL: URL) async throws {
		let size = paper.pointSize
		let widthPoints = landscape ? size.height : size.width
		let heightPoints = landscape ? size.width : size.height
		var options = RenderOptions()
		options.pageWidthPx = widthPoints / 0.75 // points → CSS pixels
		options.pageHeightPx = heightPoints / 0.75
		let data = try await HTMLRenderer.renderPDF(html: html, baseURL: baseURL, options: options)
		try writeData(data, to: outputURL)
	}

	private func htmlString(from source: HTMLSource) throws -> (html: String, baseURL: URL?) {
		switch source {
		case .string(let html, let baseURL):
			return (html, baseURL)
		case .file(let fileURL, _):
			let html = try String(contentsOf: fileURL, encoding: .utf8)
			return (html, fileURL.deletingLastPathComponent())
		}
	}

	#if os(macOS)
	/// Returns the page size in points, respecting orientation (WebKit path).
	private func pageSize() -> CGSize {
		let size = paper.pointSize
		if landscape {
			return CGSize(width: size.height, height: size.width)
		}
		return CGSize(width: size.width, height: size.height)
	}
	#endif

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
		// Resolves relative paths against the current directory and recognizes
		// platform-native absolute paths (POSIX "/…" and Windows "C:\…" / UNC).
		URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
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
func markdownToHTML(
	_ markdown: String,
	paper: PaperSize,
	landscape: Bool,
	pageBreakBefore: HeadingBreakLevel? = nil,
	extraCSS: String? = nil,
	title: String? = nil,
	authors: [String] = []
) -> String {
	let orientation = landscape ? "landscape" : "portrait"
	let pageCSS = "\(paper.cssName) \(orientation)"
	let body = MarkdownToHTML.convert(markdown)
	// Optional forced page break before a given heading level (e.g. h2 so each
	// chapter starts on a new page). Placed after the base heading rules so it
	// wins on source order; the leading break is ignored by the print engine
	// when the heading is the first box, so no blank first page is emitted.
	let headingBreakCSS = pageBreakBefore.map { level in
		"""
		\(level.rawValue) { page-break-before: always; break-before: page; }
		"""
	} ?? ""
	var metadata = title.map { "<title>\(escapeHTMLMetadata($0))</title>\n" } ?? ""
	for author in authors where !author.isEmpty {
		metadata += "<meta name=\"author\" content=\"\(escapeHTMLMetadata(author, attribute: true))\">\n"
	}
	return """
	<!DOCTYPE html>
	<html lang="en">
	<head>
	<meta charset="utf-8">
	<meta name="viewport" content="width=device-width, initial-scale=1">
	\(metadata)<style>
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
	\(MarkdownAlertLayout.css)
	.markdown-alert { page-break-inside: avoid; break-inside: avoid; }
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
	table { border-collapse: collapse; margin: 0.8em 0; font-size: 0.95em; max-width: calc(100% - 2px); }
	thead { display: table-header-group; }
	tr { page-break-inside: avoid; break-inside: avoid; }
	th, td {
	    border: 1px solid #999;
	    padding: 0.4em 0.7em;
	    text-align: left;
	    overflow-wrap: break-word;
	    word-break: normal;
	    min-width: 4em;
	}
	/* Fixed per-cell minimums must not push genuinely wide tables off the page. */
	table:has(tr > :nth-child(12)) {
	    table-layout: fixed;
	    width: calc(100% - 2px);
	}
	table:has(tr > :nth-child(12)) th,
	table:has(tr > :nth-child(12)) td { min-width: 0; }
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
	\(headingBreakCSS)
	\(extraCSS.map { "\n/* User stylesheet */\n" + $0 } ?? "")
	</style>
	</head>
	<body>
	\(body)
	</body>
	</html>
	"""
}

private func escapeHTMLMetadata(_ value: String, attribute: Bool = false) -> String {
	var escaped = value
		.replacingOccurrences(of: "&", with: "&amp;")
		.replacingOccurrences(of: "<", with: "&lt;")
		.replacingOccurrences(of: ">", with: "&gt;")
	if attribute {
		escaped = escaped
			.replacingOccurrences(of: "\"", with: "&quot;")
			.replacingOccurrences(of: "'", with: "&#39;")
	}
	return escaped
}
