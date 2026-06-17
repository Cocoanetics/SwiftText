#if OCR && os(macOS)
@_exported import SwiftTextOCR
#endif

#if PDF && os(macOS)
@_exported import SwiftTextPDF
#endif

#if DOCX
@_exported import SwiftTextDOCX
#endif

#if PAGES
@_exported import SwiftTextPages
#endif

// Platform-agnostic Markdown → AttributedText, always available.
@_exported import SwiftTextAttributedString
