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
				html = markdownToHTML(md, paper: paper, landscape: landscape, passThroughRawHTML: true)
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
///
/// Raw HTML passes through only for authored Markdown; text derived from other
/// formats (e.g. DOCX) keeps its literal angle brackets escaped.
func markdownToHTML(
	_ markdown: String,
	paper: PaperSize,
	landscape: Bool,
	passThroughRawHTML: Bool = false,
	pageBreakBefore: HeadingBreakLevel? = nil,
	extraCSS: String? = nil,
	title: String? = nil,
	authors: [String] = [],
	linkCitations: Bool = false,
	footnotes: FootnotePlacement = .section,
	language: String = "en",
	frontMatter: FrontMatter? = nil
) -> String {
	let orientation = landscape ? "landscape" : "portrait"
	let pageCSS = "\(paper.cssName) \(orientation)"
	// Printable area (paper minus the 2cm `@page` margin) in CSS pixels.
	let paperPoints = paper.pointSize
	let marginPx = 2 / 2.54 * 96
	let printableWidth = (landscape ? paperPoints.height : paperPoints.width) / 0.75 - 2 * marginPx
	let printableHeight = (landscape ? paperPoints.width : paperPoints.height) / 0.75 - 2 * marginPx
	var options: MarkdownToHTML.Options = [.headingIDs]
	if passThroughRawHTML { options.insert(.passThroughRawHTML) }
	if linkCitations { options.insert(.linkCitations) }
	if footnotes == .end { options.insert(.footnotesAtEnd) }
	let body = MarkdownToHTML.convert(markdown, options: options)
	// Optional forced page break before a given heading level (e.g. h2 so each
	// chapter starts on a new page). Placed after the base heading rules so it
	// wins on source order. The first block of the document is exempt: WebKit
	// honours a leading break and would emit a blank first page.
	let headingBreakCSS = pageBreakBefore.map { level in
		"""
		\(level.rawValue) { page-break-before: always; break-before: page; }
		body > \(level.rawValue):first-child { page-break-before: auto; break-before: auto; }
		"""
	} ?? ""
	// A front-matter block ends with a forced break; when the body opens with a
	// breaking heading, that heading breaks too and the two would leave a blank
	// page between them. The heading keeps its break and the last front-matter
	// block drops its own, so a user stylesheet that changes the block's break
	// cannot remove both.
	var frontMatterBreakCSS = ""
	if let frontMatter, let level = pageBreakBefore,
	   body.hasPrefix("<\(level.rawValue)>") || body.hasPrefix("<\(level.rawValue) ") {
		let last = frontMatter.contents != nil ? "nav.toc" : (frontMatter.titlePage != nil ? ".titlepage" : "")
		if !last.isEmpty { frontMatterBreakCSS = "\(last) { page-break-after: auto; break-after: auto; }" }
	}
	var frontMatterHTML = ""
	if let titlePage = frontMatter?.titlePage { frontMatterHTML += FrontMatterHTML.titlePage(titlePage) + "\n" }
	if let contents = frontMatter?.contents {
		frontMatterHTML += FrontMatterHTML.contents(contents, headings: FrontMatterHTML.headings(in: body)) + "\n"
	}
	var metadata = title.map { "<title>\(escapeHTMLMetadata($0))</title>\n" } ?? ""
	for author in authors where !author.isEmpty {
		metadata += "<meta name=\"author\" content=\"\(escapeHTMLMetadata(author, attribute: true))\">\n"
	}
	return """
	<!DOCTYPE html>
	<html lang="\(escapeHTMLMetadata(language, attribute: true))">
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
	/* An empty cell keeps a line's height, so fill-in rows have room to write in. */
	th:empty::after, td:empty::after { content: "\\00a0"; }
	/* Fixed per-cell minimums must not push wide tables off the page. Columns still
	   size by content, so a word only breaks if it alone is wider than that. */
	table.wide-table {
	    width: calc(100% - 2px);
	}
	table.wide-table th,
	table.wide-table td {
	    min-width: 0;
	    padding: 0.3em;
	}
	table:has(tr > :nth-child(8)) {
	    width: calc(100% - 2px);
	}
	table:has(tr > :nth-child(8)) th,
	table:has(tr > :nth-child(8)) td {
	    min-width: 0;
	    padding: 0.3em;
	}
	/* On screen a wide table scrolls rather than widening the page; print fits
	   it to the page instead (see the WebKit print preparation). */
	@media screen {
	    table.wide-table,
	    table:has(tr > :nth-child(8)) {
	        display: block;
	        overflow-x: auto;
	    }
	}
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
	\(footnotes == .page ? footnotePageCSS : "")
	\(headingBreakCSS)
	\(frontMatter == nil ? "" : FrontMatterHTML.css)
	\(frontMatterBreakCSS)
	\(extraCSS.map { "\n/* User stylesheet */\n" + $0 } ?? "")
	</style>
	</head>
	<body>
	\(frontMatterHTML)\(body)
	\(footnotes == .page ? footnotePageScript(printableWidth: printableWidth, printableHeight: printableHeight) : "")
	</body>
	</html>
	"""
}

/// Styles for `--footnotes page`: one box per printed page, the notes in a
/// rule-topped area at its foot.
private let footnotePageCSS = """
.fn-page { display: flex; flex-direction: column; width: 100%; }
.fn-page:not(:last-child) { page-break-after: always; break-after: page; }
.fn-body { flex: none; }
.fn-notes { margin-top: auto; border-top: 1px solid #999; padding-top: 0.4em; font-size: 0.85em; line-height: 1.35; }
.fn-notes:empty { display: none; }
.fn-notes .footnote-definition { margin: 0.2em 0; font-size: inherit; }
"""

/// Print-time pagination for `--footnotes page`. WebKit has no paged-media
/// footnotes, so on `beforeprint` the top-level blocks are distributed over page
/// boxes of exactly one printable page height; every box gets the notes of the
/// references it holds below its content. The body fills a page until what is
/// left is the room its notes need: a block that does not fit is split into its
/// child blocks (list items, quoted paragraphs) or at the last word break that
/// still fits (keeping two lines on either side), so each part takes the notes
/// of the references it holds. A heading that would end a page moves to the next
/// one with the text that follows it, and notes too long for the page are split
/// and continued at the foot of the next. A block that cannot be split and is
/// taller than a page still flows over the page break with its notes after it.
private func footnotePageScript(printableWidth: Double, printableHeight: Double) -> String {
	"""
	<script>
	\(PrintTableFitting.script)
	window.addEventListener('beforeprint', function () {
	    // WebKit fires beforeprint before it applies the print media rules, so lay
	    // the notes out with them in force (and screen-only rules off), and with
	    // wide tables already fitted to the page as they will be printed.
	    withPrintStyles(function () {
	        document.querySelectorAll('table').forEach(fitTable);
	        placeFootnotes();
	    });
	}, { once: true });
	function placeFootnotes() {
	    var layoutWidth = document.documentElement.clientWidth;
	    if (layoutWidth <= 0) return;
	    var printable = window.__swiftTextPrintableSize || [\(printableWidth), \(printableHeight)];
	    var pageHeight = Math.floor(printable[1] * layoutWidth / printable[0]) - 2;
	    var notes = {};
	    document.querySelectorAll('.footnote-definition').forEach(function (n) { notes[n.id] = n; n.remove(); });
	    var blocks = Array.from(document.body.children).filter(function (e) { return e.tagName !== 'SCRIPT'; });
	    // Read the break rules while the blocks are still attached to the document.
	    var breaksBefore = blocks.map(function (b) {
	        var style = getComputedStyle(b);
	        return /^(page|always|left|right)$/.test(style.getPropertyValue('break-before'))
	            || style.getPropertyValue('page-break-before') === 'always';
	    });
	    var breaksAfter = blocks.map(function (b) {
	        var style = getComputedStyle(b);
	        return /^(page|always|left|right)$/.test(style.getPropertyValue('break-after'))
	            || style.getPropertyValue('page-break-after') === 'always';
	    });
	    var holder = document.createElement('div');
	    blocks.forEach(function (b) { holder.appendChild(b); });
	    var placed = {}, carry = [], stack = [];
	    var body, area, parent, count = 0, last = null, lastNotes = [];
	    function fits() { return body.offsetHeight + area.offsetHeight <= pageHeight; }
	    function notesFor(block) {
	        var found = [];
	        block.querySelectorAll('sup a[href^="#fn-"]').forEach(function (a) {
	            var id = a.getAttribute('href').slice(1);
	            if (notes[id] && !placed[id]) {
	                placed[id] = true;
	                found.push(notes[id]);
	                // A note referenced only from another note goes on the same page.
	                found = found.concat(notesFor(notes[id]));
	            }
	        });
	        return found;
	    }
	    function addNotes(block) {
	        var found = notesFor(block);
	        found.forEach(function (n) { area.appendChild(n); });
	        return found;
	    }
	    function unplace(found) { found.forEach(function (n) { n.remove(); placed[n.id] = false; }); }
	    function commit(node, found) { last = node; lastNotes = found; count++; }
	    // The part of a split block that starts a page: no top margin, no second marker.
	    function continuation(el) {
	        el.removeAttribute('id');
	        el.classList.add('fn-cont');
	        el.style.marginTop = '0';
	        if (el.tagName === 'LI') el.style.listStyle = 'none';
	        return el;
	    }
	    function newPage(keepWithNext) {
	        var levels = body ? [body].concat(stack.map(function (s) { return s.shell; })) : [];
	        var moving = null, level = -1;
	        // A heading must not end a page: it moves on with the text that follows it.
	        if (keepWithNext && last && count > 1 && /^H[1-6]$/.test(last.tagName)) {
	            level = levels.indexOf(last.parentNode);
	            if (level >= 0) { moving = last; unplace(lastNotes); moving.remove(); }
	        }
	        for (var i = levels.length - 1; i > 0; i--) if (!levels[i].firstChild) levels[i].remove();
	        var page = document.createElement('div');
	        page.className = 'fn-page';
	        page.style.minHeight = pageHeight + 'px';
	        page.innerHTML = '<div class="fn-body"></div><div class="fn-notes"></div>';
	        document.body.insertBefore(page, document.body.lastElementChild);
	        body = page.querySelector('.fn-body'); area = page.querySelector('.fn-notes');
	        carry.forEach(function (n) { area.appendChild(n); });
	        carry = [];
	        parent = body;
	        levels = [body];
	        stack.forEach(function (s) {
	            s.shell = continuation(s.source.cloneNode(false));
	            parent.appendChild(s.shell);
	            parent = s.shell;
	            levels.push(parent);
	        });
	        count = 0; last = null; lastNotes = [];
	        if (moving) {
	            levels[level].insertBefore(moving, levels[level + 1] || null);
	            commit(moving, addNotes(moving));
	        }
	    }
	    // The child blocks of a container, or null when it holds text or inline content.
	    function blockChildren(node) {
	        if (/^(H[1-6]|TABLE|PRE|FIGURE|IMG)$/.test(node.tagName)) return null;
	        var kids = [];
	        for (var c = node.firstChild; c; c = c.nextSibling) {
	            if (c.nodeType === 3 && c.data.trim()) return null;
	            if (c.nodeType !== 1) continue;
	            if (!/^(block|list-item|flex|grid|flow-root)$/.test(getComputedStyle(c).display)) return null;
	            kids.push(c);
	        }
	        return kids.length ? kids : null;
	    }
	    // Counts the line boxes of el; a raised reference mark does not start a new one.
	    function lines(el) {
	        var style = getComputedStyle(el), range = document.createRange();
	        var lineHeight = parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.2;
	        range.selectNodeContents(el);
	        var bottoms = Array.from(range.getClientRects())
	            .filter(function (r) { return r.width > 0 && r.height > 0; })
	            .map(function (r) { return r.bottom; })
	            .sort(function (a, b) { return a - b; });
	        var count = 0, line = -Infinity;
	        bottoms.forEach(function (b) { if (b - line > lineHeight / 2) { count++; line = b; } });
	        return count;
	    }
	    function wordBreaks(el) {
	        var points = [], walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT), text, match;
	        while ((text = walker.nextNode())) {
	            var space = /\\s+/g;
	            while ((match = space.exec(text.data))) points.push([text, match.index + match[0].length]);
	        }
	        return points;
	    }
	    // The part of el before (head) or after a word break, as a shallow copy of el.
	    function cut(el, point, head) {
	        var range = document.createRange();
	        if (head) { range.setStart(el, 0); range.setEnd(point[0], point[1]); }
	        else { range.setStart(point[0], point[1]); range.setEnd(el, el.childNodes.length); }
	        var part = el.cloneNode(false);
	        part.appendChild(range.cloneContents());
	        if (head) part.style.marginBottom = '0';
	        return part;
	    }
	    // Moves the notes that overflow the page to the next one; the first of them
	    // is split at the last word break that still fits.
	    function spill() {
	        var moved = [];
	        while (!fits() && area.lastChild) moved.unshift(area.removeChild(area.lastChild));
	        if (!fits()) { moved.forEach(function (n) { area.appendChild(n); }); return; }
	        if (!moved.length) return;
	        lastNotes = [];
	        var note = moved[0], points = wordBreaks(note), best = -1, low = 0, high = points.length - 1;
	        while (low <= high) {
	            var mid = (low + high) >> 1, head = cut(note, points[mid], true);
	            area.appendChild(head);
	            if (fits()) { best = mid; low = mid + 1; } else high = mid - 1;
	            head.remove();
	        }
	        if (best >= 0) {
	            area.appendChild(cut(note, points[best], true));
	            moved[0] = continuation(cut(note, points[best], false));
	        }
	        carry = moved;
	    }
	    // Places the head of a block that does not fit (at least two lines, leaving at
	    // least two) on this page and its tail on the next. On an empty page whose
	    // first lines need more room for their notes than there is, those lines are
	    // placed anyway and the notes split.
	    function split(node, empty) {
	        parent.appendChild(node);
	        var total = lines(node), points = wordBreaks(node);
	        node.remove();
	        if (total < 4) return false;
	        var cache = {};
	        function probe(i) {
	            if (cache[i]) return cache[i];
	            var head = cut(node, points[i], true);
	            parent.appendChild(head);
	            var found = addNotes(head);
	            cache[i] = { lines: lines(head), fits: fits(), bodyFits: body.offsetHeight <= pageHeight };
	            unplace(found);
	            head.remove();
	            return cache[i];
	        }
	        var best = -1, low = 0, high = points.length - 1, mid, forced = false;
	        while (low <= high) {
	            mid = (low + high) >> 1;
	            if (probe(mid).fits && probe(mid).lines <= total - 2) { best = mid; low = mid + 1; } else high = mid - 1;
	        }
	        if (best < 0 || probe(best).lines < 2) {
	            if (!empty) return false;
	            best = -1; low = 0; high = points.length - 1;
	            while (low <= high) {
	                mid = (low + high) >> 1;
	                if (probe(mid).lines <= 2) { best = mid; low = mid + 1; } else high = mid - 1;
	            }
	            if (best < 0 || probe(best).lines < 2 || !probe(best).bodyFits) return false;
	            forced = true;
	        }
	        var head = cut(node, points[best], true), tail = continuation(cut(node, points[best], false));
	        parent.appendChild(head);
	        commit(head, addNotes(head));
	        if (forced) spill();
	        newPage(true);
	        place(tail);
	        return true;
	    }
	    // Places one block with its notes, splitting it when it does not fit.
	    function place(node) {
	        parent.appendChild(node);
	        var found = addNotes(node);
	        if (fits()) { commit(node, found); return; }
	        var empty = count === 0, style = getComputedStyle(node);
	        // List items carry break-inside: avoid in the base sheet; with notes at the
	        // foot that would leave the page short, so they split like paragraphs.
	        var avoid = node.tagName !== 'LI'
	            && /avoid/.test(style.getPropertyValue('break-inside') + style.getPropertyValue('page-break-inside'));
	        var kids = blockChildren(node);
	        var splittable = !kids && !/^(H[1-6]|TABLE|PRE|FIGURE|IMG|HR)$/.test(node.tagName) && !node.querySelector('table, pre');
	        unplace(found);
	        node.remove();
	        if (avoid && !empty) { newPage(true); place(node); return; }
	        if (kids) {
	            var shell = node.cloneNode(false);
	            if (node.tagName === 'OL') {
	                // Number the items explicitly so a continued list counts on.
	                var reversed = node.hasAttribute('reversed'), items = kids.filter(function (k) { return k.tagName === 'LI'; });
	                var number = node.hasAttribute('start') ? parseInt(node.getAttribute('start'), 10) : (reversed ? items.length : 1);
	                items.forEach(function (li) {
	                    if (li.hasAttribute('value')) number = parseInt(li.getAttribute('value'), 10);
	                    li.value = number;
	                    number += reversed ? -1 : 1;
	                });
	            }
	            parent.appendChild(shell);
	            stack.push({ source: node, shell: shell });
	            parent = shell;
	            kids.forEach(place);
	            stack.pop();
	            parent = stack.length ? stack[stack.length - 1].shell : body;
	            return;
	        }
	        // Under a lone heading the first lines go on this page even when their notes
	        // must be split: on a new page the heading would stand alone.
	        if (splittable && split(node, empty || (count === 1 && /^H[1-6]$/.test(last.tagName)))) return;
	        if (!empty) { newPage(true); place(node); return; }
	        parent.appendChild(node);
	        commit(node, addNotes(node));
	        spill();
	    }
	    newPage(false);
	    blocks.forEach(function (block, index) {
	        block.style.breakBefore = 'auto';
	        block.style.pageBreakBefore = 'auto';
	        if (breaksBefore[index] && count) newPage(false);
	        place(block);
	        if (breaksAfter[index] && index < blocks.length - 1) newPage(false);
	    });
	    if (carry.length) newPage(false);
	    // Drop the unused empty note areas so they draw no rule.
	    document.querySelectorAll('.fn-notes:empty').forEach(function (n) { n.remove(); });
	}
	</script>
	"""
}

func escapeHTMLMetadata(_ value: String, attribute: Bool = false) -> String {
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
