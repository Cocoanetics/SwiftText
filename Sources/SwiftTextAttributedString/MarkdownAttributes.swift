import Foundation

/// A GitHub-/DocC-style callout kind, carried on an alert's runs via
/// ``SwiftTextMarkdownAttributes/Alert``.
///
/// Foundation's `PresentationIntent` has no alert concept — it treats
/// `> [!NOTE]` blockquotes as ordinary quotes with literal `[!NOTE]` text. The
/// renderer recognizes them (matching the rest of the package), strips the
/// marker, and tags the quote's runs with this kind instead.
public enum MarkdownAlert: String, Codable, Sendable, Hashable, CaseIterable {
	case note
	case tip
	case important
	case warning
	case caution
	case experiment

	/// The human-readable title (e.g. "Note", "Warning").
	public var title: String {
		switch self {
		case .note: return "Note"
		case .tip: return "Tip"
		case .important: return "Important"
		case .warning: return "Warning"
		case .caution: return "Caution"
		case .experiment: return "Experiment"
		}
	}

	/// Whether the callout denotes a warning rather than information.
	public var isWarning: Bool {
		switch self {
		case .warning, .caution: return true
		case .note, .tip, .important, .experiment: return false
		}
	}

	/// Resolves a GitHub `[!TOKEN]` / DocC `Token:` identifier (case-insensitive).
	public init?(token: String) {
		guard let match = MarkdownAlert(rawValue: token.lowercased()) else { return nil }
		self = match
	}
}

/// Custom `AttributedString` attribute keys for Markdown semantics that
/// Foundation's `PresentationIntent` / `InlinePresentationIntent` can't express.
///
/// They are grouped into ``AttributeScopes/SwiftTextMarkdownAttributeScope`` so
/// they participate in dynamic-member lookup (`run.footnoteReference`,
/// `run.alert`, …) alongside the Foundation attributes the renderer also sets
/// (`.link`, `.inlinePresentationIntent`, `.presentationIntent`).
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
public enum SwiftTextMarkdownAttributes {

	/// The footnote number carried by a `[^id]` reference run.
	public enum FootnoteReference: AttributedStringKey {
		public typealias Value = Int
		public static let name = "SwiftText.footnoteReference"
	}

	/// The footnote number a trailing definition paragraph belongs to.
	public enum FootnoteDefinition: AttributedStringKey {
		public typealias Value = Int
		public static let name = "SwiftText.footnoteDefinition"
	}

	/// The callout kind carried by the runs of a GitHub/DocC alert.
	public enum Alert: AttributedStringKey {
		public typealias Value = MarkdownAlert
		public static let name = "SwiftText.alert"
	}

	/// The source URL/path of an image (Foundation keeps only the alt text).
	public enum ImageSource: AttributedStringKey {
		public typealias Value = String
		public static let name = "SwiftText.imageSource"
	}
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension AttributeScopes {

	/// The SwiftText Markdown attribute scope: the custom keys above plus the
	/// Foundation scope (so `.link`, presentation intents, etc. resolve too).
	public struct SwiftTextMarkdownAttributeScope: AttributeScope {
		public let footnoteReference: SwiftTextMarkdownAttributes.FootnoteReference
		public let footnoteDefinition: SwiftTextMarkdownAttributes.FootnoteDefinition
		public let alert: SwiftTextMarkdownAttributes.Alert
		public let imageSource: SwiftTextMarkdownAttributes.ImageSource
		public let foundation: FoundationAttributes
	}

	/// Accessor used to opt into the scope (e.g. `\.swiftTextMarkdown`).
	public var swiftTextMarkdown: SwiftTextMarkdownAttributeScope.Type {
		SwiftTextMarkdownAttributeScope.self
	}
}

@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
extension AttributeDynamicLookup {
	/// Enables `run.footnoteReference`, `run.alert`, etc. for the SwiftText scope.
	public subscript<T: AttributedStringKey>(
		dynamicMember keyPath: KeyPath<AttributeScopes.SwiftTextMarkdownAttributeScope, T>
	) -> T {
		self[T.self]
	}
}
