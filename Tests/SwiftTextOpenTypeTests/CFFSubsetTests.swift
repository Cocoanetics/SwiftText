//  CFFSubsetTests.swift
//  SwiftTextOpenTypeTests

import Foundation
import Testing
@testable import SwiftTextOpenType
#if canImport(CoreText)
import CoreText
#endif

@Suite("CFF subsetting")
struct CFFSubsetTests {
	/// A CID-keyed CFF face inside a collection: the case that used to embed
	/// the whole 23 MB `.ttc`.
	static let hiragino = "/System/Library/Fonts/Hiragino Sans GB.ttc"

	static var hiraginoAvailable: Bool { FileManager.default.fileExists(atPath: hiragino) }

	private func loadHiragino() throws -> OpenTypeFont {
		try OpenTypeFont(data: Data(contentsOf: URL(fileURLWithPath: Self.hiragino)), fontIndex: 0)
	}

	private func glyphs(_ text: String, in font: OpenTypeFont) -> [Int: Unicode.Scalar] {
		var result: [Int: Unicode.Scalar] = [:]
		for scalar in text.unicodeScalars {
			if let glyph = font.glyphID(for: scalar) { result[glyph] = scalar }
		}
		return result
	}

	@Test("A CID-keyed CFF subset is small and keeps glyph identifiers", .enabled(if: hiraginoAvailable))
	func subsetIsSmall() throws {
		let font = try loadHiragino()
		#expect(font.hasCFFOutlines)
		let used = glyphs("日本語テキスト", in: font)
		let subset = try #require(try font.subsetCFF(glyphs: used))

		#expect(subset.data.count < 500_000)
		#expect(subset.data.prefix(4) == Data("OTTO".utf8))
		for glyph in used.keys { #expect(subset.glyphMapping[glyph] == glyph) }

		// The subset parses as a font with the same glyph count and metrics.
		let reparsed = try OpenTypeFont(data: subset.data)
		#expect(reparsed.numGlyphs == font.numGlyphs)
		for (glyph, scalar) in used {
			#expect(reparsed.glyphID(for: scalar) == glyph)
			#expect(reparsed.advanceWidth(glyph: glyph) == font.advanceWidth(glyph: glyph))
		}
	}

	#if canImport(CoreText)
	@Test("Kept glyphs draw the same outlines as the original face", .enabled(if: hiraginoAvailable))
	func outlinesSurvive() throws {
		let font = try loadHiragino()
		let used = glyphs("日本語テキスト漢字", in: font)
		let subset = try #require(try font.subsetCFF(glyphs: used))
		let standalone = try font.standaloneFont()

		func ctFont(_ data: Data) throws -> CTFont {
			let descriptor = try #require(CTFontManagerCreateFontDescriptorFromData(data as CFData))
			return CTFontCreateWithFontDescriptor(descriptor, 1000, nil)
		}
		let original = try ctFont(standalone)
		let subsetFont = try ctFont(subset.data)

		for glyph in used.keys {
			let cgGlyph = CGGlyph(glyph)
			let expected = try #require(CTFontCreatePathForGlyph(original, cgGlyph, nil))
			let actual = try #require(CTFontCreatePathForGlyph(subsetFont, cgGlyph, nil))
			#expect(actual.boundingBoxOfPath == expected.boundingBoxOfPath)
			#expect(!actual.isEmpty)
		}
	}
	#endif

	@Test("A standalone face is extracted from a collection", .enabled(if: hiraginoAvailable))
	func standaloneFromCollection() throws {
		let font = try loadHiragino()
		let data = try font.standaloneFont()
		#expect(data.prefix(4) == Data("OTTO".utf8))
		#expect(data.count < font.data.count)
		#expect(try OpenTypeFont(data: data).numGlyphs == font.numGlyphs)
	}

	@Test("TrueType fonts are not CFF-subset")
	func trueTypeIsNotCFF() throws {
		let paths = ["/System/Library/Fonts/Supplemental/Arial Unicode.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]
		guard let path = paths.first(where: FileManager.default.fileExists(atPath:)) else { return }
		let font = try OpenTypeFont(data: Data(contentsOf: URL(fileURLWithPath: path)))
		#expect(try font.subsetCFF(glyphs: [1: "A"]) == nil)
	}
}
