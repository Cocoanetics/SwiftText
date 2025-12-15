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
		abstract: "Extract text from PDF or image sources.",
		version: "1.0",
		subcommands: [OCR.self],
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
			let (blocks, lookupStorage) = try await extractDocumentBlocks(from: pdfDocument)
			let textLines = pdfDocument.textLines()
			var imageLookup = lookupStorage
			let output = DocumentBlockMarkdownRenderer.markdown(
				from: blocks,
				textLines: convertToDocumentBlockLines(textLines)
			) { block in
				imageLookup.pop(for: block)
			}
			return output
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
				let result = try await documentBlocks(from: cgImage)
				let textLines = cgImage.textLines(imageSize: pageSize)
				
				var imageLookup = try saveImagesIfNeeded(images: result.images)
				let output = DocumentBlockMarkdownRenderer.markdown(
					from: result.blocks,
					textLines: convertToDocumentBlockLines(textLines)
				) { block in
					imageLookup.pop(for: block)
				}
				return output
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
	
	private func resolvedURL(from path: String) -> URL {
		let expanded = (path as NSString).expandingTildeInPath
		
		if expanded.hasPrefix("/") {
			return URL(fileURLWithPath: expanded)
		} else {
			let currentDirectory = FileManager.default.currentDirectoryPath
			return URL(fileURLWithPath: currentDirectory).appendingPathComponent(expanded)
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
	
	private func convertToDocumentBlockLines(_ lines: [TextLine]) -> [DocumentBlock.TextLine] {
		lines.map { line in
			let bounds = line.fragments.reduce(line.fragments.first?.bounds ?? .zero) { $0.union($1.bounds) }
			return DocumentBlock.TextLine(text: line.combinedText, bounds: bounds)
		}
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
