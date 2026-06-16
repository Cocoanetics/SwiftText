import Foundation

/// Finds the cross-object references inside an IWA object payload.
///
/// Every link between iWork objects is a `TSP.Reference` (`{ uint64 identifier = 1 }`,
/// plus two deprecated fields) or a `TSP.DataReference` (`{ uint64 identifier = 1 }`)
/// embedded somewhere in the payload's message tree. The loader doesn't re-scan for
/// them at read time — it trusts the record framing, where each object's `MessageInfo`
/// lists its referenced object ids in `object_references` (`#5`) and data ids in
/// `data_references` (`#6`). So to *synthesize* a valid object we must recompute those
/// lists, and to garbage-collect a graph we must know what each object reaches.
///
/// The scan is schema-less: walk every length-delimited field as a candidate
/// sub-message and, whenever a sub-message carries an `identifier` (`#1` varint) that
/// matches a known object id, record it as a reference. Restricting to *known* ids is
/// what makes this exact rather than heuristic — object ids live in a high, sparse
/// range (~1.7M in a blank document), so a stray varint elsewhere in the tree
/// effectively never collides with a real id. Validated by reproducing Apple's stored
/// `object_references` for every object in the blank template.
enum IWAReferenceScanner {
	/// The object ids referenced anywhere in `payload`, restricted to ids in `known`,
	/// in first-seen order (deduplicated). This is a *complete* set — validated to
	/// never miss a reference Apple records in `object_references` across the blank
	/// template (it's a superset: Apple additionally omits some style/back-pointer
	/// references that it resolves through the stylesheet, which is safe to include
	/// since the targets exist). Use it to compute `#5` for synthesized objects and to
	/// drive reachability; for unchanged objects, prefer preserving the original `#5`.
	static func referencedObjectIDs(in payload: [UInt8], known: Set<UInt64>) -> [UInt64] {
		var found = [UInt64]()
		var seen = Set<UInt64>()
		// The payload itself is the object, not a reference; only its descendants can be.
		for field in ProtobufMessage(payload).fields {
			if case .lengthDelimited(let bytes) = field.value, !bytes.isEmpty {
				walk(ProtobufMessage(bytes), known: known, found: &found, seen: &seen, depth: 1)
			}
		}
		return found
	}

	/// A `TSP.Reference`/`DataReference` is structurally narrow: an `identifier` at
	/// `#1` and *only* the two deprecated scalars at `#2`/`#3` alongside it. Requiring
	/// the field set to be confined to `{1,2,3}` rejects the common false positive — an
	/// ordinary message whose `#1` happens to be a small scalar (a version, kind, or
	/// count) that collides with the low-numbered document-root ids.
	private static func isReferenceShaped(_ message: ProtobufMessage) -> Bool {
		guard case .varint = message.fields.first(where: { $0.number == 1 })?.value else { return false }
		return message.fields.allSatisfy { (1...3).contains($0.number) }
	}

	private static func walk(_ message: ProtobufMessage, known: Set<UInt64>, found: inout [UInt64], seen: inout Set<UInt64>, depth: Int) {
		guard depth < 64 else { return }
		if isReferenceShaped(message), let id = message.varint(1), known.contains(id) {
			if seen.insert(id).inserted { found.append(id) }
			return  // a reference holds no nested objects
		}
		for field in message.fields {
			if case .lengthDelimited(let bytes) = field.value, !bytes.isEmpty {
				let child = ProtobufMessage(bytes)
				// Only recurse into things that actually decode as a message; this skips
				// strings/blobs (which rarely parse cleanly into nested fields) cleanly.
				if !child.fields.isEmpty { walk(child, known: known, found: &found, seen: &seen, depth: depth + 1) }
			}
		}
	}
}

/// An editable, typed model of a whole iWork document: the components (the
/// `Index/*.iwa` files) and the objects inside them, plus the non-archive files
/// (`Metadata/`, previews). It is the layer where *cold synthesis* happens — you read a
/// package in, allocate fresh object ids, add or replace objects built from the
/// generated typed models, and write a valid package back out, with the record framing
/// (`object_references`) and `PackageMetadata` high-water mark recomputed from the model
/// rather than copied.
///
/// The shared `TS*` object layer is identical across Pages, Numbers, and Keynote, so
/// this model is app-agnostic; an app layer (e.g. a Pages document builder) supplies the
/// app-specific root object (`TP`/`TN`/`KN`) and wires it into the shared content.
struct IWAObjectGraph {
	/// One `Index/*.iwa` component: a path and its records, in archive order.
	struct Component {
		var path: String
		var records: [IWARecord]
	}

	/// The IWA components, in package order.
	var components: [Component]
	/// Non-archive package files (`Metadata/…`, `preview*.jpg`), kept verbatim.
	var rawFiles: [(path: String, bytes: [UInt8])]

	// MARK: Import / export

	/// Builds a graph from a parsed package, splitting `.iwa` files into components and
	/// keeping every other file raw.
	static func read(_ package: IWAPackage) -> IWAObjectGraph {
		var components = [Component]()
		var rawFiles = [(path: String, bytes: [UInt8])]()
		for file in package.files {
			switch file.content {
			case .iwa(let records): components.append(Component(path: file.path, records: records))
			case .raw(let bytes): rawFiles.append((file.path, bytes))
			}
		}
		return IWAObjectGraph(components: components, rawFiles: rawFiles)
	}

	/// Lowers the graph back to a package ready to write. Synthesized records (built via
	/// ``addObject`` / ``replacePayload``) get their `object_references` recomputed here;
	/// unchanged records keep Apple's original framing.
	func package() -> IWAPackage {
		var files = [(path: String, content: IWAPackage.Content)]()
		for component in components { files.append((component.path, .iwa(component.records))) }
		for raw in rawFiles { files.append((raw.path, .raw(raw.bytes))) }
		return IWAPackage(files: files)
	}

	// MARK: Queries

	/// Every object id present anywhere in the graph (used as the scanner's known set).
	var allIdentifiers: Set<UInt64> {
		var ids = Set<UInt64>()
		for component in components { for record in component.records { ids.insert(record.identifier) } }
		return ids
	}

	/// The largest object id in use (the floor for `PackageMetadata.last_object_identifier`).
	var maxIdentifier: UInt64 { allIdentifiers.max() ?? 0 }

	/// The type number of an object, if present.
	func type(of identifier: UInt64) -> UInt64? {
		for component in components {
			for record in component.records where record.identifier == identifier { return record.type }
		}
		return nil
	}

	/// The object ids an object references, computed from its payload (complete superset).
	func referencedIDs(of identifier: UInt64) -> [UInt64] {
		let known = allIdentifiers
		for component in components {
			for record in component.records where record.identifier == identifier {
				var ids = [UInt64]()
				var seen = Set<UInt64>()
				for part in record.parts {
					for id in IWAReferenceScanner.referencedObjectIDs(in: part.payload, known: known) where seen.insert(id).inserted {
						ids.append(id)
					}
				}
				return ids
			}
		}
		return []
	}

	/// The set of objects reachable from `roots` by following references (mark phase of
	/// a mark-and-sweep). Everything outside it is dead and can be pruned.
	func reachable(from roots: [UInt64]) -> Set<UInt64> {
		let known = allIdentifiers
		// Index payloads by id once so traversal is not quadratic over components.
		var payloadsByID = [UInt64: [[UInt8]]]()
		for component in components {
			for record in component.records { payloadsByID[record.identifier, default: []].append(contentsOf: record.parts.map(\.payload)) }
		}
		var visited = Set<UInt64>()
		var stack = roots.filter { known.contains($0) }
		while let id = stack.popLast() {
			guard visited.insert(id).inserted else { continue }
			for payload in payloadsByID[id] ?? [] {
				for ref in IWAReferenceScanner.referencedObjectIDs(in: payload, known: known) where !visited.contains(ref) {
					stack.append(ref)
				}
			}
		}
		return visited
	}

	// MARK: Mutation

	/// Reserves and returns a fresh object id, one past the current high-water mark.
	/// (Callers that add several objects should call this once per object.)
	mutating func allocateIdentifier() -> UInt64 {
		let next = maxIdentifier + 1
		// Reserve it immediately by parking a placeholder isn't needed — callers add the
		// object right after; but to support batch allocation before adding, track it.
		reservedFloor = max(reservedFloor, next)
		return max(next, reservedFloor)
	}

	/// A floor that rises as ids are handed out, so back-to-back `allocateIdentifier()`
	/// calls don't collide before the objects are actually inserted.
	private var reservedFloor: UInt64 = 0

	/// Adds a synthesized object (its references recomputed on export) to the component
	/// at `componentPath`, creating the component if necessary. Returns its id.
	@discardableResult
	mutating func addObject(identifier: UInt64? = nil, type: UInt64, payload: [UInt8], toComponent componentPath: String) -> UInt64 {
		let id = identifier ?? allocateIdentifier()
		reservedFloor = max(reservedFloor, id + 1)
		let known = allIdentifiers.union([id])
		let refs = IWAReferenceScanner.referencedObjectIDs(in: payload, known: known)
		let record = IWARecord(identifier: id, parts: [.synthesized(type: type, payload: payload, references: refs)])
		if let index = components.firstIndex(where: { $0.path == componentPath }) {
			components[index].records.append(record)
		} else {
			components.append(Component(path: componentPath, records: [record]))
		}
		return id
	}

	/// Replaces an object's payload and marks it synthesized, so its `object_references`
	/// are recomputed from the new bytes on export. References are computed against the
	/// whole graph, so links to any existing object resolve.
	mutating func replacePayload(of identifier: UInt64, type: UInt64? = nil, with payload: [UInt8]) {
		let known = allIdentifiers
		let refs = IWAReferenceScanner.referencedObjectIDs(in: payload, known: known)
		for c in components.indices {
			for r in components[c].records.indices where components[c].records[r].identifier == identifier {
				let resolvedType = type ?? components[c].records[r].type
				components[c].records[r].parts = [.synthesized(type: resolvedType, payload: payload, references: refs)]
				return
			}
		}
	}

	// MARK: PackageMetadata

	/// The `TSP.PackageMetadata` (type 11006) object, with its component and id, if present.
	private func packageMetadata() -> (component: Int, record: Int, id: UInt64)? {
		for c in components.indices {
			for r in components[c].records.indices where components[c].records[r].type == 11006 {
				return (c, r, components[c].records[r].identifier)
			}
		}
		return nil
	}

	/// Raises `PackageMetadata.last_object_identifier` (`#1`) to cover every id now in
	/// the graph. Pages refuses to assign new ids below this water mark, so any object
	/// we synthesized above the original mark must be reflected here. The rest of the
	/// metadata payload (components, datas) is preserved verbatim.
	mutating func syncPackageMetadata() {
		guard let location = packageMetadata() else { return }
		let highWater = maxIdentifier
		let record = components[location.component].records[location.record]
		guard let part = record.parts.first else { return }
		let current = ProtobufMessage(part.payload).varint(1) ?? 0
		guard highWater > current else { return }
		// Rewrite only field #1; re-emit every other field verbatim and in order.
		var writer = ProtobufWriter()
		var wrote = false
		for field in ProtobufMessage(part.payload).fields {
			if field.number == 1 { writer.varintField(1, highWater); wrote = true }
			else { writer.append(field) }
		}
		if !wrote { writer.varintField(1, highWater) }
		// Preserve the original framing (its references are unchanged by an id bump).
		components[location.component].records[location.record].parts[0].payload = writer.bytes
	}
}
