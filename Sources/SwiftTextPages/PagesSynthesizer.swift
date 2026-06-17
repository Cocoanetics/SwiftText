import Foundation

/// Synthesizes a `.pages` document by composing a typed object graph, rather than
/// byte-patching a captured archive.
///
/// This is the graph-driven path: a document is read into an ``IWAObjectGraph`` (the
/// app-agnostic shared `TS*` object layer plus the Pages `TP` root), its content objects
/// are replaced or added as typed models, and the package is lowered back out with the
/// record framing (`object_references`) and `PackageMetadata` high-water mark recomputed
/// from the model. The bundled blank document supplies the *theme* — the stylesheet and
/// the document scaffold — exactly as a Pages theme would; everything the caller sets
/// (the body text and its runs, synthesized character styles, links) is built fresh.
///
/// Compared with ``PagesWriter`` (which surgically edits archive bytes), the synthesizer
/// keeps the whole document as an editable graph, so references and metadata are derived
/// generically — the same machinery extends to Numbers (`TN`) and Keynote (`KN`), whose
/// content sits on the identical `TS*` layer.
public final class PagesSynthesizer {
	private var graph: IWAObjectGraph

	/// Starts from the bundled blank Pages document (the default theme + scaffold).
	public init() {
		let entries = PagesTemplate.blank.entries.compactMap { entry -> (path: String, bytes: [UInt8])? in
			PagesTemplate.blank.data(for: entry.path).map { (entry.path, $0) }
		}
		graph = IWAObjectGraph.read(IWAPackage.read(entries))
	}

	/// Replaces the document body with `paragraphs`, building the text storage and any
	/// character-style / hyperlink objects they need as typed models, then placing them
	/// in the graph. Mirrors ``PagesWriter``'s body construction but routes every object
	/// through the graph so references and metadata are recomputed, not hand-patched.
	func setBody(_ paragraphs: [BodyParagraph]) throws {
		guard let bodyStorageID = bodyStorageIdentifier() else { throw PagesWriteError.bodyStorageNotFound }
		guard let templatePayload = payload(of: bodyStorageID) else { throw PagesWriteError.bodyStorageNotFound }

		let registry = CharacterStyleRegistry()
		let newBody = PagesBodySerializer.body(from: paragraphs, templatePayload: templatePayload, registry: registry)
		graph.replacePayload(of: bodyStorageID, type: 2001, with: newBody)

		// Place every synthesized style/link object alongside the body in Document.iwa.
		for object in registry.synthesizedObjects {
			graph.addObject(identifier: object.identifier, type: object.type, payload: object.payload, toComponent: "Index/Document.iwa")
		}
		graph.syncPackageMetadata()
	}

	/// Writes the synthesized document to `url` (a STORED `.pages` zip), giving it a
	/// fresh identity so each written file is a distinct document.
	public func write(to url: URL) throws {
		applyFreshIdentity()
		try graph.package().write(to: url)
	}

	/// Convenience: a document whose body is `text`, paragraphs split on newlines.
	public func write(text: String, to url: URL) throws {
		let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false).map {
			BodyParagraph(text: String($0), paragraphStyle: PagesStyleID.body)
		}
		try setBody(paragraphs)
		try write(to: url)
	}

	// MARK: Internals

	/// The body text storage id: the `TP.DocumentArchive` root (type 10000) points at it
	/// through `body_storage` (`#4`).
	private func bodyStorageIdentifier() -> UInt64? {
		guard let rootPayload = payload(ofType: 10000),
		      let reference = ProtobufMessage(rootPayload).message(4) else { return nil }
		return reference.varint(1)
	}

	/// The payload of an object by id (first part), if present.
	private func payload(of identifier: UInt64) -> [UInt8]? {
		for component in graph.components {
			for record in component.records where record.identifier == identifier { return record.parts.first?.payload }
		}
		return nil
	}

	/// The payload of the first object of a given type, if present.
	private func payload(ofType type: UInt64) -> [UInt8]? {
		for component in graph.components {
			for record in component.records where record.type == type { return record.parts.first?.payload }
		}
		return nil
	}

	/// Rewrites `Metadata/Properties.plist` UUIDs and `Metadata/DocumentIdentifier` so
	/// each written document is distinct (matching ``PagesWriter``'s identity policy).
	private func applyFreshIdentity() {
		let documentUUID = UUID().uuidString
		let versionUUID = UUID().uuidString
		let privateUUID = UUID().uuidString
		for index in graph.rawFiles.indices {
			switch graph.rawFiles[index].path {
			case "Metadata/DocumentIdentifier":
				graph.rawFiles[index].bytes = Array(documentUUID.utf8)
			case "Metadata/Properties.plist":
				if let plist = try? PropertyListSerialization.propertyList(from: Data(graph.rawFiles[index].bytes), options: [], format: nil) as? [String: Any] {
					var updated = plist
					updated["documentUUID"] = documentUUID
					updated["shareUUID"] = documentUUID
					updated["stableDocumentUUID"] = documentUUID
					updated["privateUUID"] = privateUUID
					updated["versionUUID"] = versionUUID
					updated["revision"] = "0::" + versionUUID
					if let out = try? PropertyListSerialization.data(fromPropertyList: updated, format: .binary, options: 0) {
						graph.rawFiles[index].bytes = [UInt8](out)
					}
				}
			default:
				break
			}
		}
	}
}
