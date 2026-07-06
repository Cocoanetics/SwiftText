//
//  MarkdownCommand.swift
//  SwiftText
//
//  Created by Oliver Drobnik on 24.02.26.
//

import ArgumentParser
import Foundation
import SwiftTextDOCX
import SwiftTextEPUB
import SwiftTextHTML
import SwiftTextPages
import SwiftTextRender

enum RenderOutputFormat: String, ExpressibleByArgument, CaseIterable {
	case html
	case pdf
	case docx
	case pages
	case epub
}

/// Heading level before which a page break is forced (PDF/HTML print output),
/// also reused as the EPUB chapter-split level.
enum HeadingBreakLevel: String, ExpressibleByArgument, CaseIterable {
	case h1, h2, h3, h4, h5, h6

	/// The numeric level 1–6.
	var numericLevel: Int { Int(rawValue.dropFirst()) ?? 1 }
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Render: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "render",
		abstract: "Render a Markdown file to HTML, PDF, DOCX, Pages, or EPUB. Output format is inferred from -o extension or set via --format."
	)

	@Argument(help: "Path to a .md/.markdown file. Omit when using --stdin.")
	var input: String?

	@Flag(name: .long, help: "Read Markdown from standard input instead of a file.")
	var stdin: Bool = false

	@Option(name: .shortAndLong, help: "Output path (.html, .pdf, .docx, .pages, or .epub). If omitted, defaults to input filename with the chosen extension (or output.html when using --stdin).")
	var output: String?

	@Option(name: .long, help: "Override output format (html|pdf|docx|pages|epub). If omitted, inferred from output extension; defaults to html.")
	var format: RenderOutputFormat?

	@Option(name: .long, help: "Paper size for PDF/HTML print CSS: a4, letter (default: a4).")
	var paper: PaperSize = .a4

	@Flag(name: .long, help: "Use landscape orientation (default: portrait).")
	var landscape: Bool = false

	@Option(name: .long, help: "For PDF/HTML output, force a page break before every heading of this level (h1–h6). Use h2 to start each chapter on its own page. Omit to disable.")
	var pageBreakBefore: HeadingBreakLevel?

	@Flag(name: .long, help: "For Pages output, write a directory-package bundle instead of a single file.")
	var package: Bool = false

	@Option(name: .long, help: "For PDF output, the rendering engine: webkit (macOS only, full CSS) or swift (cross-platform, no WebKit). Defaults to webkit on macOS, swift elsewhere.")
	var engine: RenderEngine = .platformDefault

	// MARK: EPUB / shared options

	@Option(name: .long, help: "Custom CSS file, applied to HTML, PDF, and EPUB output (appended after the built-in styles so its rules win).")
	var css: String?

	@Option(name: .long, help: "For EPUB output, a cover image file (JPEG/PNG). Apple Books wants at least 1400px wide.")
	var cover: String?

	@Option(name: .long, help: "For EPUB output, the book title (dc:title). Defaults to the first top-level heading, or the input filename.")
	var title: String?

	@Option(name: .long, help: "For EPUB output, an author (dc:creator). Repeat for multiple authors.")
	var author: [String] = []

	@Option(name: .long, help: "For EPUB output, the BCP-47 language tag (dc:language). Default: en.")
	var language: String = "en"

	@Option(name: .long, help: "For EPUB output, the heading level (h1–h6) that starts each chapter file. Default: h1.")
	var chapterLevel: HeadingBreakLevel = .h1

	func run() async throws {
		#if os(macOS)
		guard #available(macOS 12.0, *) else {
			throw ValidationError("The render command requires macOS 12 or newer.")
		}
		#else
		if engine == .webkit {
			throw ValidationError("The webkit engine is only available on macOS; use --engine swift.")
		}
		#endif

		let markdownText: String
		let baseURL: URL?

		if stdin {
			guard input == nil else {
				throw ValidationError("Provide either an input path or --stdin, not both.")
			}
			markdownText = readAllStdin()
			baseURL = nil
		} else {
			guard let input else {
				throw ValidationError("Provide an input path, or use --stdin.")
			}
			let fileURL = resolvedFileURL(input)
			guard FileManager.default.fileExists(atPath: fileURL.path) else {
				throw ValidationError("File not found: \(fileURL.path)")
			}
			markdownText = try String(contentsOf: fileURL, encoding: .utf8)
			baseURL = fileURL.deletingLastPathComponent()
		}

		let chosenFormat = try resolvedFormat()
		let outputURL = try resolvedOutputURL(format: chosenFormat)
		let userCSS = try loadUserCSS()

		switch chosenFormat {
		case .html:
			let html = markdownToHTML(markdownText, paper: paper, landscape: landscape, pageBreakBefore: pageBreakBefore, extraCSS: userCSS)
			try writeString(html, to: outputURL)
			print(outputURL.path)
		case .pdf:
			let html = markdownToHTML(markdownText, paper: paper, landscape: landscape, pageBreakBefore: pageBreakBefore, extraCSS: userCSS)
			try await renderPDF(html: html, baseURL: baseURL, outputURL: outputURL)
			print(outputURL.path)
		case .docx:
			try MarkdownToDocx.convert(markdownText, to: outputURL, pageSetup: docxPageSetup(), baseURL: baseURL)
			print(outputURL.path)
		case .pages:
			try MarkdownToPages.convert(markdownText, to: outputURL, packaging: package ? .package : .singleFile, baseURL: baseURL)
			print(outputURL.path)
		case .epub:
			try renderEPUB(markdownText, baseURL: baseURL, outputURL: outputURL, userCSS: userCSS)
			print(outputURL.path)
		}
	}

	// MARK: - EPUB

	private func renderEPUB(_ markdown: String, baseURL: URL?, outputURL: URL, userCSS: String?) throws {
		var coverData: Data?
		var coverFilename: String?
		if let cover {
			let coverURL = resolvedFileURL(cover)
			guard FileManager.default.fileExists(atPath: coverURL.path) else {
				throw ValidationError("Cover image not found: \(coverURL.path)")
			}
			coverData = try Data(contentsOf: coverURL)
			coverFilename = coverURL.lastPathComponent
		}

		let resolvedTitle = title ?? inferTitle(from: markdown) ?? (input.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Untitled")

		let metadata = EpubMetadata(
			title: resolvedTitle,
			authors: author,
			language: language,
			coverImage: coverData,
			coverImageFilename: coverFilename)
		let options = EpubOptions(chapterLevel: chapterLevel.numericLevel, userCSS: userCSS)
		try MarkdownToEpub.convert(markdown, to: outputURL, metadata: metadata, options: options)
	}

	/// The first ATX heading's text, used as a default EPUB title. Skips fenced
	/// code blocks so a `# …` line inside ``` fences isn't mistaken for a heading.
	private func inferTitle(from markdown: String) -> String? {
		var fence: Character?
		for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			// Toggle in/out of a fenced code block on ``` or ~~~.
			if line.hasPrefix("```") || line.hasPrefix("~~~") {
				let marker = line.first!
				if fence == nil { fence = marker } else if fence == marker { fence = nil }
				continue
			}
			guard fence == nil, line.hasPrefix("#") else { continue }
			let hashes = line.prefix { $0 == "#" }
			guard (1...6).contains(hashes.count) else { continue }
			let rest = line.dropFirst(hashes.count)
			guard rest.first == " " else { continue }
			let text = rest.trimmingCharacters(in: .whitespaces)
			if !text.isEmpty { return text }
		}
		return nil
	}

	/// Loads the `--css` file if given.
	private func loadUserCSS() throws -> String? {
		guard let css else { return nil }
		let cssURL = resolvedFileURL(css)
		guard FileManager.default.fileExists(atPath: cssURL.path) else {
			throw ValidationError("CSS file not found: \(cssURL.path)")
		}
		return try String(contentsOf: cssURL, encoding: .utf8)
	}

	// MARK: - Helpers

	private func resolvedFormat() throws -> RenderOutputFormat {
		if let format { return format }
		if let output {
			let ext = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).pathExtension.lowercased()
			if ext == "pdf" { return .pdf }
			if ext == "html" || ext == "htm" { return .html }
			if ext == "docx" { return .docx }
			if ext == "pages" { return .pages }
			if ext == "epub" { return .epub }
			throw ValidationError("Cannot infer format from output extension '.\(ext)'. Use --format html|pdf|docx|pages|epub.")
		}
		return .html
	}

	private func resolvedOutputURL(format: RenderOutputFormat) throws -> URL {
		if let output {
			let expanded = (output as NSString).expandingTildeInPath
			return URL(fileURLWithPath: expanded)
		}

		if let input {
			let fileURL = resolvedFileURL(input)
			let ext = extensionForFormat(format)
			return fileURL.deletingPathExtension().appendingPathExtension(ext)
		}

		let ext = extensionForFormat(format)
		return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
			.appendingPathComponent("output")
			.appendingPathExtension(ext)
	}

	private func extensionForFormat(_ format: RenderOutputFormat) -> String {
		switch format {
		case .html: return "html"
		case .pdf: return "pdf"
		case .docx: return "docx"
		case .pages: return "pages"
		case .epub: return "epub"
		}
	}

	private func resolvedFileURL(_ path: String) -> URL {
		// Resolves relative paths against the current directory and recognizes
		// platform-native absolute paths (POSIX "/…" and Windows "C:\…" / UNC).
		URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
	}

	private func readAllStdin() -> String {
		var lines: [String] = []
		while let line = readLine(strippingNewline: false) {
			lines.append(line)
		}
		return lines.joined()
	}

	private func writeString(_ s: String, to url: URL) throws {
		let dir = url.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try s.write(to: url, atomically: true, encoding: .utf8)
	}

	private func docxPageSetup() -> DocxPageSetup {
		switch (paper, landscape) {
		case (.a4, false):     return .a4
		case (.a4, true):      return .a4Landscape
		case (.letter, false): return .letter
		case (.letter, true):  return .letterLandscape
		}
	}

	#if os(macOS)
	private func pageSize() -> CGSize {
		let size = paper.pointSize
		if landscape {
			return CGSize(width: size.height, height: size.width)
		}
		return CGSize(width: size.width, height: size.height)
	}
	#endif

	@MainActor
	@available(macOS 12.0, *)
	private func renderPDF(html: String, baseURL: URL?, outputURL: URL) async throws {
		if engine == .swift {
			try await renderPDFSwift(html: html, outputURL: outputURL)
			return
		}
		#if os(macOS)
		// If we have a baseURL (file input), write HTML next to source so local images can load.
		// Otherwise, render from an HTML string.
		if let baseURL {
			let tempHTML = baseURL.appendingPathComponent(".\(UUID().uuidString).html")
			try html.write(to: tempHTML, atomically: true, encoding: .utf8)
			defer { try? FileManager.default.removeItem(at: tempHTML) }

			let browser = WebKitBrowser(fileURL: tempHTML, readAccessRoot: baseURL)
			browser.frameSize = pageSize()
			browser.preserveFrameHeight = true
			await browser.waitForLoadCompletion()
			let pdfData = try await browser.exportPaginatedPDFData(paperSize: pageSize())
			try writeData(pdfData, to: outputURL)
		} else {
			let browser = WebKitBrowser(htmlString: html, baseURL: nil)
			browser.frameSize = pageSize()
			browser.preserveFrameHeight = true
			await browser.waitForLoadCompletion()
			let pdfData = try await browser.exportPaginatedPDFData(paperSize: pageSize())
			try writeData(pdfData, to: outputURL)
		}
		#else
		throw ValidationError("The webkit engine is only available on macOS; use --engine swift.")
		#endif
	}

	/// Renders the print HTML to a PDF via the cross-platform SwiftTextRender engine.
	@available(macOS 12.0, *)
	private func renderPDFSwift(html: String, outputURL: URL) async throws {
		let size = paper.pointSize
		let widthPoints = landscape ? size.height : size.width
		let heightPoints = landscape ? size.width : size.height
		var options = RenderOptions()
		options.pageWidthPx = widthPoints / 0.75 // points → CSS pixels
		options.pageHeightPx = heightPoints / 0.75
		let data = try await HTMLRenderer.renderPDF(html: html, options: options)
		try writeData(data, to: outputURL)
	}

	private func writeData(_ data: Data, to url: URL) throws {
		let dir = url.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try data.write(to: url)
	}
}
