#if canImport(UIKit) || canImport(AppKit)

import Testing
import Foundation
@testable import SwiftTextAttributedString

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite("AttributedText → NSAttributedString bridge")
struct NSAttributedStringBridgeTests {

	private func ns(_ markdown: String, _ stylesheet: AttributedText.StyleSheet = .default) -> NSAttributedString {
		MarkdownAttributedTextRenderer.convert(markdown).nsAttributedString(stylesheet: stylesheet)
	}

	/// Attributes at the first occurrence of `substring`.
	private func attributes(_ attributed: NSAttributedString, at substring: String) -> [NSAttributedString.Key: Any]? {
		let string = attributed.string as NSString
		let range = string.range(of: substring)
		guard range.location != NSNotFound else { return nil }
		return attributed.attributes(at: range.location, effectiveRange: nil)
	}

	private func isBold(_ font: SwiftTextPlatformFont) -> Bool {
		#if canImport(UIKit)
		return font.fontDescriptor.symbolicTraits.contains(.traitBold)
		#elseif canImport(AppKit)
		return font.fontDescriptor.symbolicTraits.contains(.bold)
		#endif
	}

	@Test func boldRunHasBoldFont() {
		guard let attrs = attributes(ns("Plain **strong** text."), at: "strong"),
		      let font = attrs[.font] as? SwiftTextPlatformFont else {
			Issue.record("missing font on bold run"); return
		}
		#expect(isBold(font))
	}

	@Test func linkRunHasLinkAttribute() {
		let attrs = attributes(ns("[home](https://example.com)"), at: "home")
		#expect(attrs?[.link] != nil)
	}

	@Test func headingFontIsLargerThanBody() {
		let attributed = ns("# Heading\n\nbody")
		guard let heading = attributes(attributed, at: "Heading")?[.font] as? SwiftTextPlatformFont,
		      let body = attributes(attributed, at: "body")?[.font] as? SwiftTextPlatformFont else {
			Issue.record("missing fonts"); return
		}
		#expect(heading.pointSize > body.pointSize)
		#expect(isBold(heading))
	}

	@Test func listMarkerIsPrepended() {
		#expect(ns("- item").string == "\u{2022} item")
	}

	@Test func orderedListMarkerIsPrepended() {
		#expect(ns("1. first\n2. second").string == "1. first\n2. second")
	}

	@Test func codeRunUsesCodeFontSize() {
		let stylesheet = AttributedText.StyleSheet(bodyFontSize: 16, codeFontSize: 13)
		guard let font = attributes(ns("`code`", stylesheet), at: "code")?[.font] as? SwiftTextPlatformFont else {
			Issue.record("missing font on code run"); return
		}
		#expect(font.pointSize == 13)
	}

	@Test func strikethroughRunHasStrikethroughStyle() {
		let attrs = attributes(ns("~~gone~~"), at: "gone")
		#expect(attrs?[.strikethroughStyle] != nil)
	}

	@Test func footnoteReferenceCarriesNumberAndBaseline() {
		let attributed = ns("Claim[^1].\n\n[^1]: Evidence.")
		// The reference "1" is the first digit in the string ("Claim1.").
		let attrs = attributes(attributed, at: "1")
		#expect(attrs?[.swiftTextFootnoteReference] as? NSNumber == NSNumber(value: 1))
		#expect((attrs?[.baselineOffset] as? CGFloat ?? 0) > 0)
	}

	@Test func alertBodyCarriesAlertKey() {
		let attributed = ns("> [!WARNING]\n> Careful.")
		#expect(attributes(attributed, at: "Careful.")?[.swiftTextAlert] as? String == "warning")
	}

	@Test func blockquoteIsIndented() {
		let attributed = ns("> quoted")
		guard let style = attributes(attributed, at: "quoted")?[.paragraphStyle] as? NSParagraphStyle else {
			Issue.record("missing paragraph style"); return
		}
		#expect(style.headIndent > 0)
	}
}

#endif
