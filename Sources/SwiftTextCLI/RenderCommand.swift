//
//  MarkdownCommand.swift
//  SwiftText
//
//  Created by Oliver Drobnik on 24.02.26.
//

import ArgumentParser
import Foundation
import SwiftTextDOCX
import SwiftTextHTML
import SwiftTextPages
import SwiftTextRender

enum RenderOutputFormat: String, ExpressibleByArgument, CaseIterable {
	case html
	case pdf
	case docx
	case pages
}

/// Heading level before which a page break is forced (PDF/HTML print output).
enum HeadingBreakLevel: String, ExpressibleByArgument, CaseIterable {
	case h1, h2, h3, h4, h5, h6
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Render: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "render",
		abstract: "Render a Markdown file to HTML, PDF, DOCX, or Pages. Output format is inferred from -o extension or set via --format."
	)

	@Argument(help: "Path to a .md/.markdown file. Omit when using --stdin.")
	var input: String?

	@Flag(name: .long, help: "Read Markdown from standard input instead of a file.")
	var stdin: Bool = false

	@Option(name: .shortAndLong, help: "Output path (.html or .pdf). If omitted, defaults to input filename with the chosen extension (or output.html when using --stdin).")
	var output: String?

	@Option(name: .long, help: "Override output format (html|pdf|docx|pages). If omitted, inferred from output extension; defaults to html.")
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

		switch chosenFormat {
		case .html:
			let html = markdownToHTML(markdownText, paper: paper, landscape: landscape, pageBreakBefore: pageBreakBefore)
			try writeString(html, to: outputURL)
			print(outputURL.path)
		case .pdf:
			let html = markdownToHTML(markdownText, paper: paper, landscape: landscape, pageBreakBefore: pageBreakBefore)
			try await renderPDF(html: html, baseURL: baseURL, outputURL: outputURL)
			print(outputURL.path)
		case .docx:
			try MarkdownToDocx.convert(markdownText, to: outputURL, pageSetup: docxPageSetup(), baseURL: baseURL)
			print(outputURL.path)
		case .pages:
			try MarkdownToPages.convert(markdownText, to: outputURL, packaging: package ? .package : .singleFile, baseURL: baseURL)
			print(outputURL.path)
		}
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
			throw ValidationError("Cannot infer format from output extension '.\(ext)'. Use --format html|pdf|docx|pages.")
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
		}
	}

	private func resolvedFileURL(_ path: String) -> URL {
		let expanded = (path as NSString).expandingTildeInPath
		if expanded.hasPrefix("/") {
			return URL(fileURLWithPath: expanded)
		}
		return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
			.appendingPathComponent(expanded)
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
