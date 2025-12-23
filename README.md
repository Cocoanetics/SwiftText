# SwiftText

A collection of text utilities that has its origin in getting text out of various sources for the use of LLM agents.

## Overview

SwiftText provides Swift libraries and command-line tools for extracting text from various document formats. The extracted text is optimized for use with Large Language Models (LLMs) and AI agents.

## Modules

### SwiftTextOCR

Extracts text from images using:
- **Vision OCR** - Text recognition for bitmap content

Features:
- Preserves logical line structure and reading order
- Maintains vertical spacing between paragraphs
- High-resolution OCR (300 DPI) for accurate text recognition
- Optional Markdown output using Vision document segmentation (iOS 26+, macOS 26+)

### SwiftTextPDF

Extracts text from PDFs using a combination of:
- **PDFKit text selection** - For PDFs with embedded text layers
- **Vision OCR** - Automatic fallback for scanned documents or PDFs without selectable text

Features:
- Handles multi-page documents with page break markers
- Preserves logical line structure and reading order
- Maintains vertical spacing between paragraphs

### SwiftTextDOCX

Extracts text and basic structure from DOCX archives using:
- **ZIPFoundation** to read the Word archive
- **XMLParser** to parse document, styles, and numbering

Features:
- Plain text paragraph extraction
- Markdown output with headings, emphasis, and lists

## Installation

Add SwiftText to your Swift package dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/your-repo/SwiftText.git", branch: "main")
]
```

Then add the desired target to your dependencies:

```swift
.target(
	name: "YourTarget",
	dependencies: ["SwiftTextOCR", "SwiftTextPDF", "SwiftTextDOCX"]
)
```

## Usage

### Library Usage

#### PDF (SwiftTextPDF)

```swift
import PDFKit
import SwiftTextPDF

// Load a PDF document
let pdfURL = URL(fileURLWithPath: "/path/to/document.pdf")
guard let document = PDFDocument(url: pdfURL) else {
	fatalError("Could not load PDF")
}

// Extract all text as a single string
let text = document.extractText()
print(text)

// For more control, access TextLine objects directly
let textLines = document.textLines()
for textLine in textLines {
	print("Position: \(textLine.yPosition), Text: \(textLine.combinedText)")
}
```

#### Images (SwiftTextOCR)

```swift
import SwiftTextOCR

let textLines = cgImage.textLines(imageSize: CGSize(width: cgImage.width, height: cgImage.height))
let text = textLines.string()
```

#### DOCX

```swift
import SwiftTextDOCX

let url = URL(fileURLWithPath: "/path/to/document.docx")
let docx = try DocxFile(url: url)

let plainText = docx.plainText()
let markdown = docx.markdown()
```

### Command Line Tool

Build and run the CLI:

```bash
swift build
swift run swifttext ocr /path/to/document.pdf
```

Options:
- **ocr** `--markdown`/`-m` (Vision segmentation), `--save-images <dir>`, `--output-path <file>`/`-o`
- **docx** `--markdown`/`-m` (headings and lists), `--output-path <file>`/`-o`, `--save-images`
- **overlay** `--output-path <file>`/`-o`, `--dpi <value>`, `--raw`

Examples:

```bash
# Extract formatted text from a PDF
swifttext ocr ~/Documents/report.pdf

# Using a relative path
swifttext ocr ../folder/file.pdf

# Save OCR output to a file
swifttext ocr --output-path ./output.txt ~/Documents/report.pdf

# Save images while producing Markdown from a PDF
swifttext ocr --markdown --save-images ./images ~/Documents/report.pdf

# Extract plain text from a Word document
swifttext docx ~/Documents/contract.docx

# Extract Markdown from a Word document
swifttext docx --markdown ~/Documents/contract.docx

# Save Word output to a file
swifttext docx --output-path ./contract.txt ~/Documents/contract.docx

# Extract embedded images to the output directory or current directory
swifttext docx --save-images ~/Documents/contract.docx

# Render an overlay PDF for inspection
swifttext overlay --dpi 300 ~/Documents/report.pdf
```

## Requirements

- Swift 5.9+
- Platforms: macOS, iOS, tvOS, watchOS (any version that supports PDFKit)

**Note:** 
- PDF text extraction (via PDFKit) works on any platform that supports PDFKit
- OCR fallback requires iOS 13.0+, tvOS 13.0+, or macOS 10.15+ (automatically enabled when available via availability checks)
- OCR Markdown segmentation requires iOS 26.0+, tvOS 26.0+, or macOS 26.0+

## License

MIT License
