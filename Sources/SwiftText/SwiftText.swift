#if OCR && !os(Linux)
@_exported import SwiftTextOCR
#endif

#if PDF && !os(Linux)
@_exported import SwiftTextPDF
#endif

#if DOCX
@_exported import SwiftTextDOCX
#endif
