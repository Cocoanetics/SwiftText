//
//  SwiftTextCLI.swift
//  SwiftText
//
//  Created by Oliver Drobnik on 09.12.24.
//

import ArgumentParser
import Foundation
import ImageIO
import PDFKit
import SwiftTextHTML
import SwiftTextPDF
import SwiftTextDOCX
import SwiftTextOCR
#if canImport(Vision)
import Vision
#endif
import UniformTypeIdentifiers

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
@main
struct SwiftTextCLI: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "swifttext",
		abstract: "Extract text from HTML, PDF, image, or DOCX sources.",
		version: "1.0",
		subcommands: [OCR.self, Docx.self, HTML.self, Overlay.self],
		defaultSubcommand: OCR.self
	)
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct OCR: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "ocr",
		abstract: "Extract text (or Markdown when segmented) from PDFs or images."
	)
	
	@Argument(help: "Path to the PDF or image file.")
	var path: String
	
	@Flag(name: .shortAndLong, help: "Output each line separately instead of formatted text.")
	var lines: Bool = false
	
	@Flag(name: .shortAndLong, help: "Use Vision document segmentation and emit Markdown (lists/tables/images).")
	var markdown: Bool = false
	
	@Option(name: .long, help: "Directory to save detected images when using segmentation (Markdown mode).")
	var saveImages: String?
	
	@Option(name: .shortAndLong, help: "Write output to a file instead of stdout.")
	var outputPath: String?
	
	func run() async throws {
		let fileURL = resolvedURL(from: path)
		guard FileManager.default.fileExists(atPath: fileURL.path) else {
			throw ValidationError("File not found: \(fileURL.path)")
		}
		
		let ext = fileURL.pathExtension.lowercased()
		if ["png", "jpg", "jpeg", "heic", "tif", "tiff"].contains(ext) {
			let result = try await processImage(at: fileURL)
			try writeOutputIfNeeded(result)
		} else {
			let result = try await processPDF(at: fileURL)
			try writeOutputIfNeeded(result)
		}
	}
	
	private func processPDF(at url: URL) async throws -> String {
		guard let pdfDocument = PDFDocument(url: url) else {
			throw ValidationError("Could not open PDF file: \(url.path)")
		}
		
		if markdown {
			guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else {
				throw ValidationError("Vision document segmentation is unavailable on this platform.")
			}
			let textLines = pdfDocument.textLines()
			let (blocks, lookupStorage) = try await semanticMarkdownBlocks(for: pdfDocument)
			var imageLookup = lookupStorage
			return DocumentBlockMarkdownRenderer.markdown(
				from: blocks,
				textLines: convertToDocumentBlockLines(textLines)
			) { block in
				imageLookup.pop(for: block)
			}
		}
		
		let textLines = pdfDocument.textLines()
		if lines {
			return textLines.map(\.combinedText).joined(separator: "\n")
		}
		
		return textLines.string()
	}
	
	private func processImage(at url: URL) async throws -> String {
		guard
			let source = CGImageSourceCreateWithURL(url as CFURL, nil),
			let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
		else {
			throw ValidationError("Could not decode image: \(url.path)")
		}
		
		let pageSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
		
		if markdown {
			if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
				let textLines = cgImage.textLines(imageSize: pageSize)
				let (blocks, lookup) = try await semanticMarkdownBlocks(for: cgImage, pageSize: pageSize, textLines: textLines)
				var imageLookup = lookup
				return DocumentBlockMarkdownRenderer.markdown(
					from: blocks,
					textLines: convertToDocumentBlockLines(textLines)
				) { block in
					imageLookup.pop(for: block)
				}
			} else {
				throw ValidationError("Vision document segmentation is unavailable on this platform.")
			}
		}
		
		// Non-markdown: fallback to OCR lines
		let textLines = cgImage.textLines(imageSize: pageSize)
		if lines {
			return textLines.map(\.combinedText).joined(separator: "\n")
		}
		
		return textLines.string()
	}
	
	private func extractDocumentBlocks(from pdfDocument: PDFDocument) async throws -> ([DocumentBlock], ImageLookup) {
		var allBlocks = [DocumentBlock]()
		var lookupStorage: [String: [String]] = [:]
		
		for pageIndex in 0..<pdfDocument.pageCount {
			guard let page = pdfDocument.page(at: pageIndex) else { continue }
			let (blocks, images) = try await page.documentBlocksWithImages(dpi: 300)
			allBlocks.append(contentsOf: blocks)
			
			let saved = try saveImagesIfNeeded(images: images, pageIndex: pageIndex)
			for (key, value) in saved.storage {
				lookupStorage[key, default: []].append(contentsOf: value)
			}
		}
		
		return (allBlocks, ImageLookup(storage: lookupStorage))
	}
	
	private func saveImagesIfNeeded(images: [DocumentImage], pageIndex: Int? = nil) throws -> ImageLookup {
		guard let savePath = saveImages else { return ImageLookup(storage: [:]) }
		
		var isDirectory: ObjCBool = false
		let expanded = (savePath as NSString).expandingTildeInPath
		if !FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) {
			try FileManager.default.createDirectory(atPath: expanded, withIntermediateDirectories: true)
		}
		
		let baseURL = URL(fileURLWithPath: expanded, isDirectory: true)
		var lookup: [String: [String]] = [:]
		
		for (index, image) in images.enumerated() {
			let filename: String
			if let pageIndex {
				filename = "page-\(pageIndex + 1)-image-\(index + 1).png"
			} else {
				filename = "image-\(index + 1).png"
			}
			
			let destinationURL = baseURL.appendingPathComponent(filename)
			try writePNG(image.image, to: destinationURL)
			
			let key = rectKey(image.bounds)
			lookup[key, default: []].append(destinationURL.path)
		}
		
		return ImageLookup(storage: lookup)
	}
	
	private func writePNG(_ cgImage: CGImage, to url: URL) throws {
		guard #available(iOS 14.0, tvOS 14.0, macOS 11.0, *) else {
			throw ValidationError("PNG export requires a newer platform.")
		}
		guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
			throw ValidationError("Unable to create image destination at \(url.path)")
		}
		CGImageDestinationAddImage(destination, cgImage, nil)
		if !CGImageDestinationFinalize(destination) {
			throw ValidationError("Failed to save image at \(url.path)")
		}
	}
	
	private func rectKey(_ rect: CGRect) -> String {
		"\(rect.minX.rounded())-\(rect.minY.rounded())-\(rect.width.rounded())-\(rect.height.rounded())"
	}
	
	private func writeOutputIfNeeded(_ contents: String) throws {
		if let outputPath {
			let expanded = (outputPath as NSString).expandingTildeInPath
			let url = URL(fileURLWithPath: expanded)
			let dir = url.deletingLastPathComponent()
			try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
			try contents.write(to: url, atomically: true, encoding: .utf8)
			return
		}
		
		print(contents)
	}
	
	private func convertToDocumentBlockLines(_ lines: [TextLine]) -> [DocumentBlock.TextLine] {
		lines.map { line in
			let bounds = line.fragments.reduce(line.fragments.first?.bounds ?? .zero) { $0.union($1.bounds) }
			return DocumentBlock.TextLine(text: line.combinedText, bounds: bounds)
		}
	}
	
	@available(iOS 26.0, tvOS 26.0, macOS 26.0, *)
	private func semanticMarkdownBlocks(for document: PDFDocument) async throws -> ([DocumentBlock], ImageLookup) {
		var combinedBlocks = [DocumentBlock]()
		var lookupStorage: [String: [String]] = [:]
		
		for pageIndex in 0..<document.pageCount {
			guard let page = document.page(at: pageIndex) else { continue }
			let semantics = try await page.documentSemantics(dpi: 300)
			let layoutSize = page.bounds(for: .mediaBox).size
			let lines = page.textLines()
			let grouped = TextLineSemanticComposer.composeBlocks(
				from: lines,
				semantics: semantics,
				layoutSize: layoutSize
			)
			combinedBlocks.append(contentsOf: grouped)
			
			let saved = try saveImagesIfNeeded(images: semantics.images, pageIndex: pageIndex)
			for (key, value) in saved.storage {
				lookupStorage[key, default: []].append(contentsOf: value)
			}
		}
		
		return (combinedBlocks, ImageLookup(storage: lookupStorage))
	}
	
	@available(iOS 26.0, tvOS 26.0, macOS 26.0, *)
	private func semanticMarkdownBlocks(for cgImage: CGImage, pageSize: CGSize, textLines: [TextLine]) async throws -> ([DocumentBlock], ImageLookup) {
		let semantics = try await documentSemantics(from: cgImage)
		let grouped = TextLineSemanticComposer.composeBlocks(
			from: textLines,
			semantics: semantics,
			layoutSize: pageSize
		)
		let lookup = try saveImagesIfNeeded(images: semantics.images)
		return (grouped, lookup)
	}
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct HTML: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "html",
		abstract: "Extract text or Markdown from HTML sources."
	)

	@Argument(help: "Path or URL to an HTML file or page.")
	var source: String

	@Flag(name: .shortAndLong, help: "Output Markdown instead of plain text.")
	var markdown: Bool = false

	@Option(name: .shortAndLong, help: "Write output to a file instead of stdout.")
	var outputPath: String?

	@Option(name: .long, help: "Directory to save downloaded images when using Markdown output.")
	var saveImages: String?

	func run() async throws {
		let (data, baseURL) = try await loadHTMLData(from: source)
		let document = try await HTMLDocument(data: data, baseURL: baseURL)
		let output: String
		if markdown {
			let folderURL = resolveOutputDirectory(from: saveImages)
			output = try await document.markdown(saveImagesAt: folderURL)
		} else {
			output = document.text()
		}
		try writeOutputIfNeeded(output)
	}

	private func loadHTMLData(from source: String) async throws -> (Data, URL?) {
		if let url = URL(string: source), let scheme = url.scheme?.lowercased() {
			if scheme == "http" || scheme == "https" {
				let data = try await fetchData(from: url)
				return (data, url)
			}
			if url.isFileURL {
				return (try Data(contentsOf: url), url)
			}
		}

		let expanded = (source as NSString).expandingTildeInPath
		let fileURL = URL(fileURLWithPath: expanded)
		guard FileManager.default.fileExists(atPath: fileURL.path) else {
			throw ValidationError("File not found: \(fileURL.path)")
		}
		return (try Data(contentsOf: fileURL), fileURL)
	}

	private func fetchData(from url: URL) async throws -> Data {
		try await withCheckedThrowingContinuation { continuation in
			let task = URLSession.shared.dataTask(with: url) { data, response, error in
				if let error {
					continuation.resume(throwing: error)
					return
				}

				guard let data else {
					continuation.resume(throwing: ValidationError("No data received from \(url.absoluteString)"))
					return
				}

				continuation.resume(returning: data)
			}
			task.resume()
		}
	}

	private func writeOutputIfNeeded(_ contents: String) throws {
		if let outputPath {
			let expanded = (outputPath as NSString).expandingTildeInPath
			let url = URL(fileURLWithPath: expanded)
			let dir = url.deletingLastPathComponent()
			try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
			try contents.write(to: url, atomically: true, encoding: .utf8)
			return
		}

		print(contents)
	}

	private func resolveOutputDirectory(from path: String?) -> URL? {
		guard let path, !path.isEmpty else {
			return nil
		}

		let expanded = (path as NSString).expandingTildeInPath
		return URL(fileURLWithPath: expanded, isDirectory: true)
	}
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Docx: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "docx",
		abstract: "Extract text from DOCX files."
	)

	@Argument(help: "Path to the DOCX file.")
	var path: String

	@Flag(name: .shortAndLong, help: "Output Markdown with headings and lists.")
	var markdown: Bool = false

	@Option(name: .shortAndLong, help: "Write output to a file instead of stdout.")
	var outputPath: String?

	@Flag(name: .long, help: "Extract embedded images to the output directory or current directory.")
	var saveImages: Bool = false

	func run() async throws {
		let fileURL = resolvedURL(from: path)
		guard FileManager.default.fileExists(atPath: fileURL.path) else {
			throw ValidationError("File not found: \(fileURL.path)")
		}

		let docx = try DocxFile(url: fileURL)
		let output = markdown ? docx.markdown() : docx.plainText()
		if !output.isEmpty {
			try writeOutputIfNeeded(output)
		}

		if saveImages {
			let destination = resolvedImageDirectory()
			_ = try docx.extractImages(to: destination)
		}
	}

	private func writeOutputIfNeeded(_ contents: String) throws {
		if let outputPath {
			let expanded = (outputPath as NSString).expandingTildeInPath
			let url = URL(fileURLWithPath: expanded)
			let dir = url.deletingLastPathComponent()
			try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
			try contents.write(to: url, atomically: true, encoding: .utf8)
			return
		}

		print(contents)
	}

	private func resolvedImageDirectory() -> URL {
		if let outputPath {
			let expanded = (outputPath as NSString).expandingTildeInPath
			return URL(fileURLWithPath: expanded).deletingLastPathComponent()
		}

		return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
	}
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Overlay: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "overlay",
		abstract: "Render a visual overlay of detected structure onto the source PDF or image."
	)
	
	@Argument(help: "Path to the PDF or image file.")
	var path: String
	
	@Option(name: .shortAndLong, help: "Write overlay to this path. Defaults to adding -overlay before the extension.")
	var outputPath: String?
	
	@Option(name: .long, help: "DPI used when rendering PDF pages.")
	var dpi: Double = 300
	
	@Flag(name: .long, help: "Render raw Vision blocks instead of reconstructed semantic blocks.")
	var raw: Bool = false
	
	func run() async throws {
		let inputURL = resolvedURL(from: path)
		guard FileManager.default.fileExists(atPath: inputURL.path) else {
			throw ValidationError("File not found: \(inputURL.path)")
		}
		
		let ext = inputURL.pathExtension.lowercased()
		if ext == "pdf" {
			let outputURL = resolvedOutputURL(for: inputURL, explicit: outputPath, defaultExtension: "pdf")
			try await renderPDFOverlay(inputURL: inputURL, outputURL: outputURL)
			print(outputURL.path)
		} else if ["png", "jpg", "jpeg", "heic", "tif", "tiff"].contains(ext) {
			let outputURL = resolvedOutputURL(for: inputURL, explicit: outputPath, defaultExtension: ext)
			try await renderImageOverlay(inputURL: inputURL, outputURL: outputURL)
			print(outputURL.path)
		} else {
			throw ValidationError("Unsupported file type for overlay: .\(ext)")
		}
	}
	
	private func renderImageOverlay(inputURL: URL, outputURL: URL) async throws {
		guard
			let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
			let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
		else {
			throw ValidationError("Could not decode image: \(inputURL.path)")
		}
		
		let pageSize = CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
		
		guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else {
			throw ValidationError("Vision document segmentation is unavailable on this platform.")
		}
		
			let textLines = cgImage.textLines(imageSize: pageSize)
			let rectangles = raw ? try detectedRectangles(from: cgImage) : []
			let blocks: [DocumentBlock]
			if raw {
				let rawBlocks = try await documentBlocks(from: cgImage, applyPostProcessing: false).blocks
				blocks = rawBlocks
			} else {
				blocks = try await reconstructedBlocks(for: cgImage, textLines: textLines)
			}
			
			let overlayImage = try OverlayRenderer.overlayImage(
				baseImage: cgImage,
				pageSize: pageSize,
				blocks: blocks,
				lines: textLines,
				rectangles: rectangles
			)
			
			try OverlayRenderer.writeImage(overlayImage, to: outputURL, suggestedExtension: inputURL.pathExtension)
	}
	
	private func renderPDFOverlay(inputURL: URL, outputURL: URL) async throws {
		guard let document = PDFDocument(url: inputURL) else {
			throw ValidationError("Could not open PDF file: \(inputURL.path)")
		}
		
		guard #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) else {
			throw ValidationError("Vision document segmentation is unavailable on this platform.")
		}
		
		let pdfContext = try OverlayRenderer.beginPDFContext(at: outputURL)
		
			for pageIndex in 0..<document.pageCount {
				guard let page = document.page(at: pageIndex) else { continue }
				
				let rectangles = raw ? try page.detectedRectangles(dpi: dpi) : []
				let (renderedPage, renderedSize) = try page.renderedPageImage(dpi: dpi)
				let textLines: [TextLine]
				if raw {
					textLines = page.textLines()
				} else {
					textLines = renderedPage.textLines(imageSize: renderedSize)
				}
				
				let blocks: [DocumentBlock]
				if raw {
					let rawBlocks = try await page.documentBlocksWithImages(dpi: dpi, applyPostProcessing: false).blocks
					blocks = postProcessBlocks(rawBlocks, pageSize: renderedSize)
				} else {
					blocks = try await reconstructedBlocks(for: renderedPage, textLines: textLines)
				}
				
				let overlay = try OverlayRenderer.overlayImage(
					baseImage: renderedPage,
					pageSize: renderedSize,
					blocks: blocks,
					lines: textLines,
					rectangles: rectangles
				)
			
			let mediaBox = page.bounds(for: .mediaBox)
			OverlayRenderer.drawPage(
				overlayImage: overlay,
				into: pdfContext,
				mediaBox: mediaBox
			)
		}
		
		pdfContext.closePDF()
	}
	
	private func resolvedOutputURL(for input: URL, explicit: String?, defaultExtension: String) -> URL {
		if let explicit {
			let expanded = (explicit as NSString).expandingTildeInPath
			return URL(fileURLWithPath: expanded)
		}
		
		let base = input.deletingPathExtension()
		let filename = base.lastPathComponent + "-overlay"
		return base.deletingLastPathComponent().appendingPathComponent(filename).appendingPathExtension(defaultExtension)
	}
}

fileprivate func resolvedURL(from path: String) -> URL {
	let expanded = (path as NSString).expandingTildeInPath
	
	if expanded.hasPrefix("/") {
		return URL(fileURLWithPath: expanded)
	} else {
		let currentDirectory = FileManager.default.currentDirectoryPath
		return URL(fileURLWithPath: currentDirectory).appendingPathComponent(expanded)
	}
}

private struct ImageLookup {
	var storage: [String: [String]]
	
	mutating func pop(for block: DocumentBlock) -> String? {
		let key = "\(block.bounds.minX.rounded())-\(block.bounds.minY.rounded())-\(block.bounds.width.rounded())-\(block.bounds.height.rounded())"
		guard var candidates = storage[key], !candidates.isEmpty else { return nil }
		let path = candidates.removeFirst()
		storage[key] = candidates
		return path
	}
}

#if canImport(Vision)
@available(iOS 26.0, tvOS 26.0, macOS 26.0, *)
private extension Overlay {
	func reconstructedBlocks(for image: CGImage, textLines: [TextLine]) async throws -> [DocumentBlock] {
		let semantics = try await documentSemantics(from: image)
		let layoutSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
		return TextLineSemanticComposer.composeBlocks(
			from: textLines,
			semantics: semantics,
			layoutSize: layoutSize
		)
	}
}
#endif
