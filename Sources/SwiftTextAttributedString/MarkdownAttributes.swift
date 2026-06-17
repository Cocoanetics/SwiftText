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

// MARK: - Portable block / inline models

/// A platform-independent description of a run's block context — the same shape
/// as Foundation's `PresentationIntent` (a chain of components, innermost
/// first, each with a kind and a document-unique identity), but available on
/// every platform.
///
/// Foundation's presentation intents live in Apple's SDK Foundation overlay and
/// are absent from cross-platform swift-foundation, so the renderer always
/// carries this value (via ``SwiftTextMarkdownAttributes/Block``) and, on Apple
/// platforms, *additionally* sets the native `presentationIntent` derived from
/// it. Reading ``Block`` therefore works identically everywhere.
public struct MarkdownBlock: Codable, Hashable, Sendable {
	/// The intent chain, innermost (leaf) first — mirrors
	/// `PresentationIntent.components`.
	public var components: [Component]

	public init(components: [Component]) {
		self.components = components
	}

	/// The leaf (innermost) kind, e.g. `.paragraph` for a list item's text.
	public var leafKind: Kind? { components.first?.kind }

	/// One level of the block hierarchy.
	public struct Component: Codable, Hashable, Sendable {
		public var kind: Kind
		/// Document-unique identity; sibling blocks share their parent's identity.
		public var identity: Int

		public init(_ kind: Kind, identity: Int) {
			self.kind = kind
			self.identity = identity
		}
	}

	/// The kind of a block — one case per `PresentationIntent.Kind`.
	public enum Kind: Codable, Hashable, Sendable {
		case paragraph
		case header(level: Int)
		case orderedList
		case unorderedList
		case listItem(ordinal: Int)
		case codeBlock(languageHint: String?)
		case blockQuote
		case thematicBreak
		case table(columns: [ColumnAlignment])
		case tableHeaderRow
		case tableRow(rowIndex: Int)
		case tableCell(columnIndex: Int)
	}

	/// Table column alignment — one case per `PresentationIntent.TableColumn.Alignment`.
	public enum ColumnAlignment: Codable, Hashable, Sendable {
		case left
		case center
		case right
	}
}

/// A platform-independent set of inline traits — the same bits as Foundation's
/// `InlinePresentationIntent`, but available on every platform. Carried via
/// ``SwiftTextMarkdownAttributes/InlineStyle``; the native
/// `inlinePresentationIntent` is set alongside it on Apple platforms.
public struct MarkdownInlineStyle: OptionSet, Codable, Hashable, Sendable {
	public let rawValue: Int
	public init(rawValue: Int) { self.rawValue = rawValue }

	public static let emphasized = MarkdownInlineStyle(rawValue: 1 << 0)
	public static let stronglyEmphasized = MarkdownInlineStyle(rawValue: 1 << 1)
	public static let code = MarkdownInlineStyle(rawValue: 1 << 2)
	public static let strikethrough = MarkdownInlineStyle(rawValue: 1 << 3)
	public static let softBreak = MarkdownInlineStyle(rawValue: 1 << 4)
	public static let lineBreak = MarkdownInlineStyle(rawValue: 1 << 5)
	public static let inlineHTML = MarkdownInlineStyle(rawValue: 1 << 6)
	public static let blockHTML = MarkdownInlineStyle(rawValue: 1 << 7)
}

// MARK: - AttributedString keys

/// Custom `AttributedString` attribute keys for Markdown semantics.
///
/// ``Block`` and ``InlineStyle`` carry block/inline structure on every platform
/// (Foundation's presentation intents are Apple-only). ``FootnoteReference``,
/// ``FootnoteDefinition``, ``Alert`` and ``ImageSource`` carry features that
/// Foundation's intents can't express at all.
///
/// They are grouped into ``AttributeScopes/SwiftTextMarkdownAttributeScope`` so
/// they participate in dynamic-member lookup (`run.alert`, …) alongside the
/// Foundation `.link` attribute the renderer also sets.
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
public enum SwiftTextMarkdownAttributes {

	/// The block context (``MarkdownBlock``) — present on every platform.
	public enum Block: AttributedStringKey {
		public typealias Value = MarkdownBlock
		public static let name = "SwiftText.block"
	}

	/// The inline traits (``MarkdownInlineStyle``) — present on every platform.
	public enum InlineStyle: AttributedStringKey {
		public typealias Value = MarkdownInlineStyle
		public static let name = "SwiftText.inlineStyle"
	}

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
	/// Foundation scope (so `.link`, and — on Apple — the native presentation
	/// intents, resolve too).
	public struct SwiftTextMarkdownAttributeScope: AttributeScope {
		public let block: SwiftTextMarkdownAttributes.Block
		public let inlineStyle: SwiftTextMarkdownAttributes.InlineStyle
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
	/// Enables `run.block`, `run.alert`, etc. for the SwiftText scope.
	public subscript<T: AttributedStringKey>(
		dynamicMember keyPath: KeyPath<AttributeScopes.SwiftTextMarkdownAttributeScope, T>
	) -> T {
		self[T.self]
	}
}
