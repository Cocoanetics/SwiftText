import Foundation
import SwiftTextIWA

public enum KeynoteParserError: Error, CustomStringConvertible {
	case fileNotFound(URL)
	case notAKeynoteDocument(URL)

	public var description: String {
		switch self {
		case .fileNotFound(let url): return "File not found: \(url.path)"
		case .notAKeynoteDocument(let url): return "Not a Keynote (iWork '13+) document: \(url.path)"
		}
	}
}

/// Reads an Apple Keynote (`.key`) presentation into a `KeynoteDocument`.
///
/// Same IWA container as Pages and Numbers, so it reuses `IWAContainer`, `IWAArchive`,
/// and `IWAObjectStore`. Keynote ships no public schema and SwiftText vendors no `KN.*`
/// models, so navigation is structural, driven by `IWAReferenceScanner`:
///
///   `KN.DocumentArchive(1)` → `KN.ShowArchive(2)` → `KN.ThemeArchive(10)` owns the
///   theme's layout (master) slides. The deck's own slides are the `KN.SlideNodeArchive(4)`
///   objects the theme does *not* own; each node references its `KN.SlideArchive(5)`,
///   whose `KN.PlaceholderArchive(7)` / `TSWP.ShapeInfoArchive(2011)` children hold the
///   text (`TSWP.StorageArchive(2001)`), and whose `KN.NoteArchive(15)` holds notes.
public struct KeynoteParser {
	private enum Const {
		static let documentArchiveType: UInt64 = 1
		static let slideNodeType: UInt64 = 4
		static let slideArchiveType: UInt64 = 5
		static let placeholderType: UInt64 = 7
		static let shapeInfoType: UInt64 = 2011
		static let noteType: UInt64 = 15
		static let storageType: UInt64 = 2001
		static let showThemeField = 2          // KN.ShowArchive → theme
		static let themeSlideNodesField = 2     // KN.ThemeArchive → layout slide nodes
		static let documentShowField = 2        // KN.DocumentArchive → show
		static let referenceIdentifierField = 1
		static let storageTextField = 3
	}

	public init() {}

	public func readDocument(from url: URL) throws -> KeynoteDocument {
		guard FileManager.default.fileExists(atPath: url.path) else {
			throw KeynoteParserError.fileNotFound(url)
		}
		let entries = try IWAContainer.entries(at: url, prefix: "Index/", suffix: ".iwa")
		guard !entries.isEmpty else { throw KeynoteParserError.notAKeynoteDocument(url) }

		var store = IWAObjectStore()
		for entry in entries {
			guard let objects = try? IWAArchive.objects(from: entry.data) else { continue }
			for object in objects { store.add(object) }
		}
		return Self.buildDocument(from: store)
	}

	static func buildDocument(from store: IWAObjectStore) -> KeynoteDocument {
		let allIDs = Set(store.objects.map(\.identifier))
		func refs(_ id: UInt64) -> [UInt64] {
			guard let object = store.object(id) else { return [] }
			return IWAReferenceScanner.referencedObjectIDs(in: object.payload, known: allIDs)
		}
		func storageText(_ id: UInt64) -> String? {
			guard let object = store.object(id), object.type == Const.storageType else { return nil }
			let text = ProtobufMessage(object.payload).allBytes(Const.storageTextField)
				.map { String(decoding: $0, as: UTF8.self) }.joined()
			// Drop placeholders that are empty or only object-replacement chars (U+FFFC),
			// e.g. an unfilled image slot.
			let meaningful = text.unicodeScalars.contains { $0 != "\u{FFFC}" && !$0.properties.isWhitespace }
			return meaningful ? text : nil
		}
		/// The first `StorageArchive` reachable one hop below `id` (a placeholder/shape
		/// wraps its storage), or the object itself when it is already a storage.
		func textBelow(_ id: UInt64) -> String? {
			if let direct = storageText(id) { return direct }
			for child in refs(id) where store.object(child)?.type == Const.storageType {
				if let text = storageText(child) { return text }
			}
			return nil
		}

		// Layout slide nodes hang off the theme; the deck's nodes are the rest.
		var layoutNodes = Set<UInt64>()
		if let doc = store.objects(ofType: Const.documentArchiveType).first,
		   let showID = ProtobufMessage(doc.payload).message(Const.documentShowField)?.varint(Const.referenceIdentifierField),
		   let show = store.object(showID),
		   let themeID = ProtobufMessage(show.payload).message(Const.showThemeField)?.varint(Const.referenceIdentifierField),
		   let theme = store.object(themeID) {
			layoutNodes = Set(ProtobufMessage(theme.payload).messages(Const.themeSlideNodesField).compactMap {
				$0.varint(Const.referenceIdentifierField)
			})
		}

		// Deck slides: slide nodes the theme does not own, in document (discovery) order.
		var slides = [KeynoteDocument.Slide]()
		for node in store.objects(ofType: Const.slideNodeType) where !layoutNodes.contains(node.identifier) {
			guard let slideID = refs(node.identifier).first(where: { store.object($0)?.type == Const.slideArchiveType }) else { continue }

			var texts = [String](), notes: String?
			for ref in refs(slideID) {
				switch store.object(ref)?.type {
				case Const.placeholderType, Const.shapeInfoType:
					if let text = textBelow(ref) { texts.append(text) }
				case Const.noteType:
					notes = notes ?? textBelow(ref)
				default:
					break
				}
			}
			// The first text shape is the title; the rest are body.
			let title = texts.first
			let body = Array(texts.dropFirst())
			slides.append(.init(title: title, body: body, notes: notes))
		}

		return KeynoteDocument(slides: slides)
	}
}
