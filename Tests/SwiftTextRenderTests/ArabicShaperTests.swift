//  ArabicShaperTests.swift
//  SwiftTextRenderTests

import Testing
import Foundation
@testable import SwiftTextRender
import SwiftTextHTML
import SwiftTextCSS

@Suite("Arabic shaping (presentation forms)")
struct ArabicShaperTests {

	/// Shape `string` (all forms assumed present unless `hasForm` says otherwise)
	/// and return the resulting scalar values for easy comparison.
	private func shaped(_ string: String, hasForm: @escaping (Unicode.Scalar) -> Bool = { _ in true }) -> [UInt32] {
		ArabicShaper.shape(string, hasForm: hasForm).unicodeScalars.map { $0.value }
	}

	// Letters used below (logical order):
	//   beh ب U+0628 (dual)   yeh ي U+064A (dual)   teh ت U+062A (dual)
	//   lam ل U+0644 (dual)   alef ا U+0627 (right) dal د U+062F (right)
	//   fatha ٠ U+064E (transparent mark)

	@Test("needsShaping fires on Arabic letters only")
	func detectsArabic() {
		#expect(ArabicShaper.needsShaping("\u{0628}\u{064A}\u{062A}"))   // بيت
		#expect(!ArabicShaper.needsShaping("Hello"))
		#expect(!ArabicShaper.needsShaping("123 שלום"))                  // Hebrew is not Arabic
	}

	@Test("A dual-joining word picks initial / medial / final")
	func joinsAcrossWord() {
		// بيت: beh(initial) yeh(medial) teh(final)
		#expect(shaped("\u{0628}\u{064A}\u{062A}") == [0xFE91, 0xFEF4, 0xFE96])
	}

	@Test("Right-joining letters do not connect to the following letter")
	func rightJoiningBreaksChain() {
		// دب: dal is right-joining, so neither letter connects — both isolated.
		#expect(shaped("\u{062F}\u{0628}") == [0xFEA9, 0xFE8F])
	}

	@Test("Lam + alef fuse into a single ligature glyph")
	func lamAlefLigature() {
		// لا alone → isolated ligature (one glyph).
		#expect(shaped("\u{0644}\u{0627}") == [0xFEFB])
		// بلا → beh(initial) + lam-alef(final ligature); still one glyph for the pair.
		#expect(shaped("\u{0628}\u{0644}\u{0627}") == [0xFE91, 0xFEFC])
	}

	@Test("Transparent harakat do not break joining")
	func harakatAreTransparent() {
		// beh + fatha + teh: the mark is skipped when joining, then passed through.
		#expect(shaped("\u{0628}\u{064E}\u{062A}") == [0xFE91, 0x064E, 0xFE96])
	}

	@Test("A missing medial glyph degrades to the final form")
	func degradesToFinal() {
		// Pretend the font lacks yeh's medial form (U+FEF4): fall back to final.
		let values = shaped("\u{0628}\u{064A}\u{062A}", hasForm: { $0.value != 0xFEF4 })
		#expect(values == [0xFE91, 0xFEF2, 0xFE96])
	}

	@Test("With no presentation-form glyphs, letters stay nominal")
	func fallsBackToNominal() {
		// A font with no presentation forms (hasForm always false) → unchanged.
		#expect(shaped("\u{0628}\u{064A}\u{062A}", hasForm: { _ in false }) == [0x0628, 0x064A, 0x062A])
	}

	#if os(macOS)
	@Test("An Arabic word is shaped and reordered end to end")
	func arabicEndToEnd() async throws {
		let candidates = [
			"/System/Library/Fonts/Supplemental/Damascus.ttc",
			"/System/Library/Fonts/Supplemental/AlBayan.ttc",
			"/System/Library/Fonts/Supplemental/Baghdad.ttc",
			"/System/Library/Fonts/Supplemental/Nadeem.ttc",
			"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
		]
		guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
			return // No Arabic system font available; skip.
		}
		let data = try Data(contentsOf: URL(fileURLWithPath: path))
		let fonts = FontBook()
		let embedded = try fonts.register(data: data, family: "Arabic")
		guard embedded.hasGlyph(for: "\u{FE91}") else {
			return // Font lacks presentation forms in its cmap; skip.
		}

		// بيت (house), in an RTL paragraph using the registered Arabic font.
		let html = "<p dir=\"rtl\" style=\"font-family: Arabic\">\u{0628}\u{064A}\u{062A}</p>"
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		let root = try #require(builder.root)
		let styled = StyledElement.build(domElement: root, resolver: StyleResolver(), baseDirection: .rtl)
		let rootBox = try #require(BoxTreeBuilder.build(from: styled) as? BlockBox)
		LayoutEngine(fonts: fonts).layout(root: rootBox, contentWidth: 300, originX: 0, originY: 0)

		let paragraph = try #require(firstBlock(in: rootBox) { $0.element?.localName == "p" })
		let fragment = try #require(paragraph.lines.first?.fragments.first)
		// Logical shaped order is FE91 FEF4 FE96; the RTL pass reverses the run for
		// visual (left-to-right) display, giving FE96 FEF4 FE91.
		#expect(fragment.text.unicodeScalars.map { $0.value } == [0xFE96, 0xFEF4, 0xFE91])
	}
	#endif

	/// First block in `box`'s subtree matching `predicate` (depth-first).
	private func firstBlock(in box: Box, where predicate: (BlockBox) -> Bool) -> BlockBox? {
		if let block = box as? BlockBox {
			if predicate(block) { return block }
			for child in block.children {
				if let found = firstBlock(in: child, where: predicate) { return found }
			}
		}
		return nil
	}
}
