import Foundation

/// Writes a `.pages` document from scratch.
///
/// Assembles a built-in template's captured object graph (see ``PagesTemplate``),
/// injects body content into its text storage, gives the document a fresh
/// identity, and re-zips — with no Apple frameworks and nothing bundled at
/// runtime beyond the template data compiled into the module.
public final class PagesWriter {
	private let template: PagesTemplate

	init(template: PagesTemplate) {
		self.template = template
	}

	/// Creates a writer backed by the built-in blank template.
	public convenience init() {
		self.init(template: .blank)
	}

	// MARK: Plain text

	/// Writes a document whose body is `text`, with paragraphs separated by
	/// newlines, in the template's default body style.
	public func write(text: String, to url: URL) throws {
		let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false).map {
			BodyParagraph(text: String($0), paragraphStyle: PagesStyleID.body)
		}
		try write(paragraphs: paragraphs, to: url)
	}

	// MARK: Structured body

	/// Writes a document whose body is the given paragraphs (each carrying its
	/// paragraph style, list membership, and inline style runs).
	func write(paragraphs: [BodyParagraph], to url: URL) throws {
		let identity = DocumentIdentity.fresh()
		let registry = CharacterStyleRegistry()
		var zip = StoredZipWriter()
		for entry in template.entries {
			guard var data = template.data(for: entry.path) else {
				throw PagesWriteError.malformedTemplate(entry.path)
			}
			switch entry.path {
			case "Index/Document.iwa":
				data = try buildDocument(from: data, paragraphs: paragraphs, registry: registry)
			case "Index/DocumentStylesheet.iwa":
				data = try applyingParagraphSpacing(to: data)
			case "Metadata/Properties.plist":
				data = try rewritingProperties(data, identity: identity)
			case "Metadata/DocumentIdentifier":
				data = Array(identity.documentUUID.utf8)
			default:
				break
			}
			zip.add(path: entry.path, data: data)
		}
		try zip.finish().write(to: url, options: .atomic)
	}

	// MARK: Document component

	/// Rebuilds `Index/Document.iwa`: replaces the body storage with serialized
	/// paragraphs, then appends any character-style objects the body references.
	private func buildDocument(from documentIWA: [UInt8], paragraphs: [BodyParagraph], registry: CharacterStyleRegistry) throws -> [UInt8] {
		let data = Data(documentIWA)
		let bodyID = try bodyStorageIdentifier(in: data)
		var edited = try IWAArchive.replacingPayload(in: data, objectID: bodyID) { payload in
			PagesBodySerializer.body(from: paragraphs, templatePayload: payload, registry: registry)
		}
		if registry.didSynthesize {
			edited = try IWAArchive.appending(registry.synthesizedObjects, to: edited)
		}
		return [UInt8](edited)
	}

	/// Paragraph spacing (points: before, after) applied to the template's
	/// body/heading styles so written documents have Markdown-like vertical rhythm
	/// (the blank template ships every style with zero spacing).
	private static let spacingSpecs: [(styleID: UInt64, before: Float, after: Float)] = [
		(PagesStyleID.body, 0, 8),
		(PagesStyleID.title, 0, 16),
		(PagesStyleID.heading1, 16, 6),
		(PagesStyleID.heading2, 14, 6),
		(PagesStyleID.heading3, 12, 4),
	]

	/// Edits `DocumentStylesheet.iwa` to give the body and heading styles paragraph
	/// spacing. Each style object is rewritten in place; all others are preserved.
	private func applyingParagraphSpacing(to stylesheetIWA: [UInt8]) throws -> [UInt8] {
		var data = Data(stylesheetIWA)
		for spec in Self.spacingSpecs {
			data = try IWAArchive.replacingPayload(in: data, objectID: spec.styleID) { payload in
				PagesBodySerializer.settingSpacing(in: payload, spaceBefore: spec.before, spaceAfter: spec.after)
			}
		}
		return [UInt8](data)
	}

	/// The identifier of the document body's text storage: the root
	/// `DocumentArchive` (type 10000) points at it via field 4.
	private func bodyStorageIdentifier(in documentIWA: Data) throws -> UInt64 {
		for object in try IWAArchive.objects(from: documentIWA) where object.type == 10000 {
			if let reference = ProtobufMessage(object.payload).message(4),
			   let identifier = reference.varint(1) {
				return identifier
			}
		}
		throw PagesWriteError.bodyStorageNotFound
	}

	// MARK: Metadata identity

	/// Replaces the document's UUIDs so each written file is a distinct document.
	private func rewritingProperties(_ data: [UInt8], identity: DocumentIdentity) throws -> [UInt8] {
		guard var plist = try PropertyListSerialization.propertyList(
			from: Data(data), options: [], format: nil
		) as? [String: Any] else {
			return data
		}
		plist["documentUUID"] = identity.documentUUID
		plist["shareUUID"] = identity.documentUUID
		plist["stableDocumentUUID"] = identity.documentUUID
		plist["privateUUID"] = identity.privateUUID
		plist["versionUUID"] = identity.versionUUID
		plist["revision"] = "0::" + identity.versionUUID
		let out = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
		return [UInt8](out)
	}
}

/// A fresh set of document identifiers for a written `.pages`.
private struct DocumentIdentity {
	let documentUUID: String
	let versionUUID: String
	let privateUUID: String

	static func fresh() -> DocumentIdentity {
		DocumentIdentity(
			documentUUID: UUID().uuidString,
			versionUUID: UUID().uuidString,
			privateUUID: UUID().uuidString
		)
	}
}

/// Errors raised while writing a `.pages` document.
public enum PagesWriteError: Error, LocalizedError {
	case malformedTemplate(String)
	case bodyStorageNotFound

	public var errorDescription: String? {
		switch self {
		case .malformedTemplate(let path):
			return "Pages template entry could not be decoded: \(path)"
		case .bodyStorageNotFound:
			return "Could not locate the document body storage in the template."
		}
	}
}
