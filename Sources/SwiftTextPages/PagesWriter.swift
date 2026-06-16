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
				data = try applyingStylesheet(to: data)
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

	/// One paragraph style's curated appearance. Every value is written into the *style
	/// object* (not per paragraph), so editing the style in Pages — e.g. resizing
	/// "Heading 1" — recascades to every paragraph that uses it.
	private struct StyleSpec {
		let id: UInt64
		var fontSize: Float? = nil          // points (char_properties)
		var spaceBefore: Float = 0          // points
		var spaceAfter: Float = 0           // points
		var lineSpacing: Float? = nil       // relative multiple
		var color: (r: Float, g: Float, b: Float)? = nil
	}

	/// The default "stylesheet" applied to generated documents — the Pages counterpart
	/// to the MD→HTML/PDF CSS. A clear size hierarchy (the blank theme's headings are
	/// nearly the same size), comfortable body line spacing, and a neutral Heading 4
	/// (the theme ships it red). Tunable defaults: the user can still edit any style.
	private static let stylesheet: [StyleSpec] = [
		.init(id: PagesStyleID.body,     spaceAfter: 8, lineSpacing: 1.2),
		.init(id: PagesStyleID.title,    fontSize: 32, spaceAfter: 16),
		.init(id: PagesStyleID.heading1, fontSize: 24, spaceBefore: 18, spaceAfter: 6),
		.init(id: PagesStyleID.heading2, fontSize: 18, spaceBefore: 16, spaceAfter: 6),
		.init(id: PagesStyleID.heading3, fontSize: 15, spaceBefore: 14, spaceAfter: 4),
		// Heading 4 is rebuilt below (the theme's "Heading Red" can't be recolored via
		// the paragraph style — see applyingStylesheet).
	]

	/// Edits `DocumentStylesheet.iwa` to install the default stylesheet: each style
	/// object is rewritten in place (size/spacing/line-spacing/color), the block-quote
	/// style is built, and link text is colored. All other styles are preserved.
	private func applyingStylesheet(to stylesheetIWA: [UInt8]) throws -> [UInt8] {
		var data = Data(stylesheetIWA)
		for spec in Self.stylesheet {
			data = try IWAArchive.replacingPayload(in: data, objectID: spec.id) { payload in
				var p = PagesBodySerializer.settingSpacing(in: payload, spaceBefore: spec.spaceBefore, spaceAfter: spec.spaceAfter)
				if let size = spec.fontSize { p = PagesBodySerializer.settingFontSize(in: p, points: size) }
				if let ls = spec.lineSpacing { p = PagesBodySerializer.settingLineSpacing(in: p, multiple: ls) }
				if let c = spec.color { p = PagesBodySerializer.settingTextColor(in: p, red: c.r, green: c.g, blue: c.b) }
				return p
			}
		}
		if let body = try IWAArchive.objects(from: data).first(where: { $0.identifier == PagesStyleID.body })?.payload {
			// Block quote: a copy of the (known-safe) Body style, indented + italic, with
			// a unique identifier. (Editing the special "Default" style crashes Pages;
			// repurposing a real style is safe.)
			var blockQuote = PagesBodySerializer.settingStyleIdentity(in: body, name: "Block Quote", identifier: PagesStyleIdentifier.blockQuote)
			blockQuote = PagesBodySerializer.settingSpacing(in: blockQuote, spaceBefore: 8, spaceAfter: 8)
			blockQuote = PagesBodySerializer.settingLeftIndent(in: blockQuote, points: 36)
			blockQuote = PagesBodySerializer.settingItalic(in: blockQuote)
			blockQuote = PagesBodySerializer.settingTextColor(in: blockQuote, red: 0.4, green: 0.4, blue: 0.4)
			data = try IWAArchive.replacingPayload(in: data, objectID: PagesStyleID.blockQuote) { _ in blockQuote }

			// Heading 4: the blank theme ships it as a red "Heading Red". Rather than
			// recolor in place, rebuild it from the Body style — black, bold, 13pt —
			// keeping the stable "Heading 4" identifier so the reader still maps
			// `####` ↔ this style.
			var heading4 = PagesBodySerializer.settingStyleIdentity(in: body, name: "Heading 4", identifier: "text-14-paragraphstyle-Heading 4")
			heading4 = PagesBodySerializer.settingBold(in: heading4)
			heading4 = PagesBodySerializer.settingFontSize(in: heading4, points: 13)
			heading4 = PagesBodySerializer.settingSpacing(in: heading4, spaceBefore: 12, spaceAfter: 4)
			data = try IWAArchive.replacingPayload(in: data, objectID: PagesStyleID.heading4) { _ in heading4 }

			// Code block ("preformatted"): a copy of Body in a monospace face, a touch
			// smaller, tight line spacing, a left inset, distinct code color, and clear
			// space before/after (the whole block is one paragraph with soft line breaks,
			// so this spacing is a margin around the block, not a gap between lines).
			// Repurposes the unused "Caption" style (real style ⇒ its para_properties apply).
			let code = PagesBodySerializer.codeTextColor
			var codeBlock = PagesBodySerializer.settingStyleIdentity(in: body, name: "Code Block", identifier: PagesStyleIdentifier.codeBlock)
			codeBlock = PagesBodySerializer.settingFontName(in: codeBlock, name: "Menlo-Regular")
			codeBlock = PagesBodySerializer.settingFontSize(in: codeBlock, points: 10)
			codeBlock = PagesBodySerializer.settingLineSpacing(in: codeBlock, multiple: 1.2)
			codeBlock = PagesBodySerializer.settingLeftIndent(in: codeBlock, points: 12)
			codeBlock = PagesBodySerializer.settingSpacing(in: codeBlock, spaceBefore: 12, spaceAfter: 12)
			codeBlock = PagesBodySerializer.settingTextColor(in: codeBlock, red: code.r, green: code.g, blue: code.b)
			data = try IWAArchive.replacingPayload(in: data, objectID: PagesStyleID.codeBlock) { _ in codeBlock }
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
