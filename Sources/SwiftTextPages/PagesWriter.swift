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
	func write(paragraphs inputParagraphs: [BodyParagraph], to url: URL) throws {
		let identity = DocumentIdentity.fresh()
		let registry = CharacterStyleRegistry()

		// Native tables: build the object set for every table paragraph and inject it
		// into the captured components (the grid lives in `Index/Tables/*`, the model
		// in the calc engine, the anchor in the body's #9 run table).
		let tables = inputParagraphs.compactMap(\.table)
		let tableArtifacts = tables.isEmpty ? nil : try PagesTableBuilder.build(tables)

		// Point each table paragraph's attachment at its (relocated) drawable-attachment
		// id, in document order, so the body's #9 run table anchors the right table.
		var paragraphs = inputParagraphs
		if let tableArtifacts {
			var tableIndex = 0
			for index in paragraphs.indices where paragraphs[index].table != nil {
				paragraphs[index].attachment = tableArtifacts.attachmentIDs[tableIndex]
				tableIndex += 1
			}
		}

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
			case "Index/Metadata.iwa" where tableArtifacts != nil:
				// Tables add `Index/Tables/*` components; use the captured table
				// document's PackageMetadata (its component layout matches the output).
				// Document.iwa is processed earlier in this loop, so `registry` already
				// reflects any synthesized objects by the time Metadata is written.
				let synthesizedMax = registry.didSynthesize ? registry.maxIdentifier : 0
				data = try tablePackageMetadata(
					highWaterMark: max(synthesizedMax, tableArtifacts!.maxObjectID),
					tableCount: tableArtifacts!.tableCount,
					styleComponentRefs: tableArtifacts!.styleComponentRefs
				)
			case "Metadata/Properties.plist":
				data = try rewritingProperties(data, identity: identity)
			case "Metadata/DocumentIdentifier":
				data = Array(identity.documentUUID.utf8)
			default:
				break
			}
			// Append any captured table records destined for this component.
			if let append = tableArtifacts?.appendsByFile[entry.path] {
				data = [UInt8](try IWAArchive.appendingRecordStream(append, to: Data(data)))
			}
			zip.add(path: entry.path, data: data)
		}
		// Add the new table component files (`Index/Tables/*`).
		if let tableArtifacts {
			for (path, fileData) in tableArtifacts.newFiles.sorted(by: { $0.key < $1.key }) {
				zip.add(path: path, data: fileData)
			}
		}
		try zip.finish().write(to: url, options: .atomic)
	}

	/// The captured table document's `PackageMetadata`, relocated to cover every
	/// table in this document: the id high-water mark (`#1`) is raised, each extra
	/// table's `Index/Tables/*` components are registered, and the cross-references
	/// are cloned at the matching id offsets (see `PagesTableBuilder`).
	private func tablePackageMetadata(highWaterMark: UInt64, tableCount: Int, styleComponentRefs: [UInt64: [UInt64]]) throws -> [UInt8] {
		guard let data = Data(base64Encoded: PagesTableTemplate.metadataBase64) else {
			throw PagesWriteError.malformedTemplate("Index/Metadata.iwa")
		}
		guard let packageMetadata = try IWAArchive.objects(from: data).first(where: { $0.type == 11006 }) else {
			return [UInt8](data)
		}
		let current = ProtobufMessage(packageMetadata.payload).varint(1) ?? 0
		let updated = try IWAArchive.replacingPayload(in: data, objectID: packageMetadata.identifier) { payload in
			PagesTableBuilder.relocateComponentMetadata(payload, tableCount: tableCount, highWaterMark: max(highWaterMark, current), styleComponentRefs: styleComponentRefs)
		}
		return [UInt8](updated)
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
		// Body line spacing: a 1.2× multiple for comfortable reading rhythm — the Pages
		// counterpart to the HTML/PDF stylesheet's `line-height: 1.6` (Pages line
		// multiples run tighter than CSS for the same perceived spacing).
		data = try IWAArchive.replacingPayload(in: data, objectID: PagesStyleID.body) { payload in
			PagesBodySerializer.settingLineSpacing(in: payload, multiple: 1.2)
		}
		// Repurpose the (unused) "Subtitle" style as an indented block-quote style by
		// overwriting it with a copy of the (known-safe) Body style plus a left indent
		// and a unique identifier. Editing/referencing a real style applies its
		// para_properties without the crash the special "Default" style caused.
		if let body = try IWAArchive.objects(from: data).first(where: { $0.identifier == PagesStyleID.body })?.payload {
			var blockQuote = PagesBodySerializer.settingStyleIdentity(in: body, name: "Block Quote", identifier: "swifttext-block-quote")
			blockQuote = PagesBodySerializer.settingSpacing(in: blockQuote, spaceBefore: 8, spaceAfter: 8)
			blockQuote = PagesBodySerializer.settingLeftIndent(in: blockQuote, points: 36)
			blockQuote = PagesBodySerializer.settingItalic(in: blockQuote)
			data = try IWAArchive.replacingPayload(in: data, objectID: PagesStyleID.blockQuote) { _ in blockQuote }
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
