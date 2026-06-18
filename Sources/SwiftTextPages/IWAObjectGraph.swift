import SwiftTextIWA
import Foundation

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
	/// One `Index/*.iwa` component: a path, its records (in archive order), and the
	/// original compressed bytes it was read from (for verbatim re-emit when unchanged).
	struct Component {
		var path: String
		var records: [IWARecord]
		var originalBytes: [UInt8]?
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
			case .iwa(let records, let original): components.append(Component(path: file.path, records: records, originalBytes: original))
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
		for component in components { files.append((component.path, .iwa(component.records, original: component.originalBytes))) }
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
			if field.number == 1 { writer.varintField(1, highWater); wrote = true } else { writer.append(field) }
		}
		if !wrote { writer.varintField(1, highWater) }
		// Preserve the original framing (its references are unchanged by an id bump).
		components[location.component].records[location.record].parts[0].payload = writer.bytes
	}
}
