//
//  SwiftTextCLI.swift
//  SwiftText
//
//  Created by Oliver Drobnik on 09.12.24.
//

import ArgumentParser
import Foundation
import PDFKit
import SwiftTextPDF

@main
struct SwiftTextCLI: ParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "swifttext",
		abstract: "Extract text from various document formats.",
		subcommands: [PDF.self],
		defaultSubcommand: PDF.self
	)
}

extension SwiftTextCLI {
	struct PDF: ParsableCommand {
		static let configuration = CommandConfiguration(
			abstract: "Extract text from a PDF file."
		)
		
		@Argument(help: "Path to the PDF file (local or absolute).")
		var path: String
		
		@Flag(name: .shortAndLong, help: "Output each line separately instead of formatted text.")
		var lines: Bool = false
		
		func run() throws {
			// Resolve the path
			let fileURL: URL
			if path.hasPrefix("/") {
				fileURL = URL(fileURLWithPath: path)
			} else {
				let currentDirectory = FileManager.default.currentDirectoryPath
				fileURL = URL(fileURLWithPath: currentDirectory).appendingPathComponent(path)
			}
			
			// Verify file exists
			guard FileManager.default.fileExists(atPath: fileURL.path) else {
				throw ValidationError("File not found: \(fileURL.path)")
			}
			
			// Load the PDF document
			guard let pdfDocument = PDFDocument(url: fileURL) else {
				throw ValidationError("Could not open PDF file: \(fileURL.path)")
			}
			
			// Extract and output text
			if lines {
				let textLines = pdfDocument.stringsFromLines
				for line in textLines {
					print(line)
				}
			} else {
				let text = pdfDocument.extractText()
				print(text)
			}
		}
	}
}


