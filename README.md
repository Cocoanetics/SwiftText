# SwiftText

A collection of text utilities that has its origin in getting text out of various sources for the use of LLM agents.

## Overview

SwiftText provides Swift libraries and command-line tools for extracting text from various document formats. The extracted text is optimized for use with Large Language Models (LLMs) and AI agents.

## Modules

### SwiftTextPDF

Extracts text from PDF documents using a combination of:
- **PDFKit text selection** - For PDFs with embedded text layers
- **Vision OCR** - Automatic fallback for scanned documents or PDFs without selectable text

Features:
- Preserves logical line structure and reading order
- Maintains vertical spacing between paragraphs
- Handles multi-page documents with page break markers
- High-resolution OCR (300 DPI) for accurate text recognition

## Installation

Add SwiftText to your Swift package dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/your-repo/SwiftText.git", from: "1.0.0")
]
```

Then add the desired target to your dependencies:

```swift
.target(
    name: "YourTarget",
    dependencies: ["SwiftTextPDF"]
)
```

## Usage

### Library Usage

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

// Or get individual lines
let lines = document.stringsFromLines
for line in lines {
    print(line)
}

// For more control, access TextLine objects directly
let textLines = document.textLines()
for textLine in textLines {
    print("Position: \(textLine.yPosition), Text: \(textLine.combinedText)")
}
```

### Command Line Tool

Build and run the CLI:

```bash
swift build
swift run swifttext pdf /path/to/document.pdf
```

Options:
- `--lines` / `-l`: Output each line separately instead of formatted text

Examples:

```bash
# Extract formatted text from a PDF
swifttext pdf ~/Documents/report.pdf

# Extract text line by line
swifttext pdf --lines ./document.pdf

# Using a relative path
swifttext pdf ../folder/file.pdf
```

## Requirements

- Swift 5.9+
- Platforms: macOS, iOS, tvOS, watchOS (any version that supports PDFKit)

**Note:** 
- PDF text extraction (via PDFKit) works on any platform that supports PDFKit
- OCR fallback requires iOS 13.0+, tvOS 13.0+, or macOS 10.15+ (automatically enabled when available via availability checks)

## License

MIT License

