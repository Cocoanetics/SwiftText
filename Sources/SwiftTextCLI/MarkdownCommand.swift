//
//  MarkdownCommand.swift
//  SwiftText
//
//  Created by Oliver Drobnik on 24.02.26.
//

#if os(macOS)
import ArgumentParser
import Foundation
import SwiftTextHTML

enum MarkdownOutputFormat: String, ExpressibleByArgument, CaseIterable {
	case html
	case pdf
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Markdown: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "markdown",
		abstract: "Render a Markdown file to HTML or PDF. Output format is inferred from -o extension or set via --format."
	)

	@Argument(help: "Path to a .md/.markdown file. Omit when using --stdin.")
	var input: String?

	@Flag(name: .long, help: "Read Markdown from standard input instead of a file.")
	var stdin: Bool = false

	@Option(name: .shortAndLong, help: "Output path (.html or .pdf). If omitted, defaults to input filename with the chosen extension (or output.html when using --stdin).")
	var output: String?

	@Option(name: .long, help: "Override output format (html|pdf). If omitted, inferred from output extension; defaults to html.")
	var format: MarkdownOutputFormat?

	@Option(name: .long, help: "Paper size for PDF/HTML print CSS: a4, letter (default: a4).")
	var paper: PaperSize = .a4

	@Flag(name: .long, help: "Use landscape orientation (default: portrait).")
	var landscape: Bool = false

	func run() async throws {
		guard #available(macOS 12.0, *) else {
			throw ValidationError("The markdown command requires macOS 12 or newer.")
		}

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
			let html = markdownToHTML(markdownText, paper: paper, landscape: landscape)
			try writeString(html, to: outputURL)
			print(outputURL.path)
		case .pdf:
			let html = markdownToHTML(markdownText, paper: paper, landscape: landscape)
			try await renderPDF(html: html, baseURL: baseURL, outputURL: outputURL)
			print(outputURL.path)
		}
	}

	// MARK: - Helpers

	private func resolvedFormat() throws -> MarkdownOutputFormat {
		if let format { return format }
		if let output {
			let ext = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).pathExtension.lowercased()
			if ext == "pdf" { return .pdf }
			if ext == "html" || ext == "htm" { return .html }
			throw ValidationError("Cannot infer format from output extension '.\(ext)'. Use --format html|pdf.")
		}
		return .html
	}

	private func resolvedOutputURL(format: MarkdownOutputFormat) throws -> URL {
		if let output {
			let expanded = (output as NSString).expandingTildeInPath
			return URL(fileURLWithPath: expanded)
		}

		if let input {
			let fileURL = resolvedFileURL(input)
			let ext = (format == .pdf) ? "pdf" : "html"
			return fileURL.deletingPathExtension().appendingPathExtension(ext)
		}

		let ext = (format == .pdf) ? "pdf" : "html"
		return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
			.appendingPathComponent("output")
			.appendingPathExtension(ext)
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

	private func pageSize() -> CGSize {
		let size = paper.pointSize
		if landscape {
			return CGSize(width: size.height, height: size.width)
		}
		return size
	}

	@MainActor
	@available(macOS 12.0, *)
	private func renderPDF(html: String, baseURL: URL?, outputURL: URL) async throws {
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
	}

	private func writeData(_ data: Data, to url: URL) throws {
		let dir = url.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try data.write(to: url)
	}
}

#endif
