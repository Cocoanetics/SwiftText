#if canImport(UIKit) || canImport(AppKit)

import Foundation

#if canImport(UIKit)
import UIKit
/// The platform font type (`UIFont` on UIKit platforms).
public typealias SwiftTextPlatformFont = UIFont
/// The platform color type (`UIColor` on UIKit platforms).
public typealias SwiftTextPlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
/// The platform font type (`NSFont` on AppKit platforms).
public typealias SwiftTextPlatformFont = NSFont
/// The platform color type (`NSColor` on AppKit platforms).
public typealias SwiftTextPlatformColor = NSColor
#endif

extension NSAttributedString.Key {
	/// `NSNumber` footnote number carried by a footnote-reference run.
	public static let swiftTextFootnoteReference = NSAttributedString.Key("SwiftTextFootnoteReference")
	/// `String` raw value of the ``AttributedText/AlertKind`` for callout runs.
	public static let swiftTextAlert = NSAttributedString.Key("SwiftTextAlert")
}

extension AttributedText {

	/// Style parameters used when bridging ``AttributedText`` to
	/// `NSAttributedString`. All sizes are in points.
	public struct StyleSheet: Sendable {
		/// Base body font size.
		public var bodyFontSize: CGFloat
		/// Monospaced (code) font size.
		public var codeFontSize: CGFloat
		/// Indentation added per list-nesting / blockquote level.
		public var indentStep: CGFloat
		/// Spacing after each paragraph.
		public var paragraphSpacing: CGFloat
		/// Link foreground color (`nil` leaves the platform default).
		public var linkColor: SwiftTextPlatformColor?
		/// Background color applied to code runs (`nil` for none).
		public var codeBackgroundColor: SwiftTextPlatformColor?
		/// Returns the font size for a heading of the given 1…6 level.
		public var headingFontSize: @Sendable (Int) -> CGFloat

		public init(
			bodyFontSize: CGFloat = 16,
			codeFontSize: CGFloat = 14,
			indentStep: CGFloat = 28,
			paragraphSpacing: CGFloat = 10,
			linkColor: SwiftTextPlatformColor? = nil,
			codeBackgroundColor: SwiftTextPlatformColor? = nil,
			headingFontSize: @escaping @Sendable (Int) -> CGFloat = StyleSheet.defaultHeadingSize
		) {
			self.bodyFontSize = bodyFontSize
			self.codeFontSize = codeFontSize
			self.indentStep = indentStep
			self.paragraphSpacing = paragraphSpacing
			self.linkColor = linkColor
			self.codeBackgroundColor = codeBackgroundColor
			self.headingFontSize = headingFontSize
		}

		/// The default heading scale (h1 = 30 … h6 = 15) relative to a 16-pt body.
		public static let defaultHeadingSize: @Sendable (Int) -> CGFloat = { level in
			switch max(1, min(level, 6)) {
			case 1: return 30
			case 2: return 24
			case 3: return 20
			case 4: return 18
			case 5: return 16
			default: return 15
			}
		}

		public static let `default` = StyleSheet()
	}

	/// Bridges this attributed text to an `NSAttributedString`, applying fonts,
	/// links, list markers, indentation and paragraph spacing from `stylesheet`.
	///
	/// List markers (`•`, `1.`, `☐`) — which live in the paragraph style rather
	/// than the run text — are prepended to the first run of each list item.
	/// Image/table/rule attachments fall back to their run text; the structured
	/// payload remains available on the source ``AttributedText``.
	public func nsAttributedString(stylesheet: StyleSheet = .default) -> NSAttributedString {
		let result = NSMutableAttributedString()
		for (index, run) in runs.enumerated() {
			let startsParagraph = index == 0 || runs[index - 1].text == "\n"
			if startsParagraph,
			   let list = run.attributes.paragraph.list,
			   !list.marker.isEmpty {
				result.append(markerString(list.marker, paragraph: run.attributes.paragraph, stylesheet: stylesheet))
			}
			result.append(NSAttributedString(string: run.text, attributes: attributes(for: run, stylesheet: stylesheet)))
		}
		return result
	}

	// MARK: - Attribute construction

	private func markerString(
		_ marker: String, paragraph: ParagraphStyle, stylesheet: StyleSheet
	) -> NSAttributedString {
		let attributes: [NSAttributedString.Key: Any] = [
			.font: font(bold: false, italic: false, code: false, size: stylesheet.bodyFontSize),
			.paragraphStyle: paragraphStyle(for: paragraph, stylesheet: stylesheet),
		]
		return NSAttributedString(string: marker, attributes: attributes)
	}

	private func attributes(for run: Run, stylesheet: StyleSheet) -> [NSAttributedString.Key: Any] {
		let attrs = run.attributes
		var result: [NSAttributedString.Key: Any] = [:]

		// Font: size from kind (heading/code/body), traits from inline style.
		var size = stylesheet.bodyFontSize
		if attrs.code {
			size = stylesheet.codeFontSize
		} else if case let .heading(level) = attrs.paragraph.kind {
			size = stylesheet.headingFontSize(level)
		}

		// Footnote references and explicit super/subscripts shrink and shift.
		var baselineOffset: CGFloat = 0
		if attrs.baseline != .normal {
			baselineOffset = size * (attrs.baseline == .superscript ? 0.35 : -0.2)
			size *= 0.7
		}

		let headingIsBold = { () -> Bool in
			if case .heading = attrs.paragraph.kind { return true }
			return false
		}()

		result[.font] = font(
			bold: attrs.bold || headingIsBold,
			italic: attrs.italic,
			code: attrs.code,
			size: size
		)
		result[.paragraphStyle] = paragraphStyle(for: attrs.paragraph, stylesheet: stylesheet)

		if attrs.strikethrough {
			result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
		}
		if baselineOffset != 0 {
			result[.baselineOffset] = baselineOffset
		}
		if let link = attrs.link, !link.isEmpty {
			result[.link] = URL(string: link) ?? link
			if let color = stylesheet.linkColor {
				result[.foregroundColor] = color
			}
		}
		if attrs.code, let background = stylesheet.codeBackgroundColor {
			result[.backgroundColor] = background
		}
		if let number = attrs.footnoteReference {
			result[.swiftTextFootnoteReference] = NSNumber(value: number)
		}
		if let alert = attrs.paragraph.alert {
			result[.swiftTextAlert] = alert.rawValue
		}
		return result
	}

	private func paragraphStyle(for paragraph: ParagraphStyle, stylesheet: StyleSheet) -> NSParagraphStyle {
		let style = NSMutableParagraphStyle()
		style.alignment = nsAlignment(paragraph.alignment)
		style.paragraphSpacing = stylesheet.paragraphSpacing

		var indentLevel = paragraph.quoteLevel
		if let list = paragraph.list {
			indentLevel += list.level + 1
		}
		switch paragraph.kind {
		case .footnoteDefinition:
			indentLevel += 1
		default:
			break
		}
		let indent = CGFloat(indentLevel) * stylesheet.indentStep
		style.headIndent = indent
		style.firstLineHeadIndent = indent
		return style
	}

	// MARK: - Platform helpers

	private func nsAlignment(_ alignment: Alignment) -> NSTextAlignment {
		switch alignment {
		case .natural: return .natural
		case .left: return .left
		case .center: return .center
		case .right: return .right
		}
	}

	private func font(bold: Bool, italic: Bool, code: Bool, size: CGFloat) -> SwiftTextPlatformFont {
		let base: SwiftTextPlatformFont = code
			? SwiftTextPlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
			: SwiftTextPlatformFont.systemFont(ofSize: size)
		guard bold || italic else { return base }
		return base.applyingSwiftTextTraits(bold: bold, italic: italic) ?? base
	}
}

// MARK: - Symbolic-trait application (platform-specific names)

extension SwiftTextPlatformFont {
	/// Returns a copy of the font with bold/italic symbolic traits applied, or
	/// `nil` if the descriptor can't be resolved.
	fileprivate func applyingSwiftTextTraits(bold: Bool, italic: Bool) -> SwiftTextPlatformFont? {
		#if canImport(UIKit)
		var traits = fontDescriptor.symbolicTraits
		if bold { traits.insert(.traitBold) }
		if italic { traits.insert(.traitItalic) }
		guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return nil }
		return UIFont(descriptor: descriptor, size: 0)
		#elseif canImport(AppKit)
		var traits = fontDescriptor.symbolicTraits
		if bold { traits.insert(.bold) }
		if italic { traits.insert(.italic) }
		let descriptor = fontDescriptor.withSymbolicTraits(traits)
		return NSFont(descriptor: descriptor, size: 0)
		#endif
	}
}

#endif
