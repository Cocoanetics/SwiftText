//
//  PDFFontStyleTests.swift
//  SwiftTextOCRTests
//

#if canImport(AppKit)
import AppKit
import CoreText
import Testing

import PDFKit
@testable import SwiftTextPDF

/// The system font's PostScript name is a private `.SFNS-…` one; reading a
/// style from it must not look the font up by that name.
struct PDFFontStyleTests {

	@Test("System font style is read without a by-name lookup")
	func systemFontStyle() throws {
		let regular = try #require(CTFontCreateUIFontForLanguage(.system, 14, nil))
		let bold = try #require(CTFontCreateUIFontForLanguage(.emphasizedSystem, 20, nil))
		let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) as CTFont

		let r = PDFPage.textStyle(of: regular)
		#expect(r.fontSize == 14)
		#expect(!r.isBold && !r.isItalic && !r.isMonospaced)

		let b = PDFPage.textStyle(of: bold)
		#expect(b.fontSize == 20)
		#expect(b.isBold)

		#expect(PDFPage.textStyle(of: mono).isMonospaced)

		let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
		#expect(PDFPage.textStyle(from: italic)?.isItalic == true)
	}
}
#endif
