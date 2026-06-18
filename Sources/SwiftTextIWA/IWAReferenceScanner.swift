import Foundation

/// Finds the cross-object references inside an IWA object payload.
///
/// Every link between iWork objects is a `TSP.Reference` (`{ uint64 identifier = 1 }`,
/// plus two deprecated fields) or a `TSP.DataReference` (`{ uint64 identifier = 1 }`)
/// embedded somewhere in the payload's message tree. The loader doesn't re-scan for
/// them at read time — it trusts the record framing, where each object's `MessageInfo`
/// lists its referenced object ids in `object_references` (`#5`) and data ids in
/// `data_references` (`#6`). So to *synthesize* a valid object we must recompute those
/// lists, to garbage-collect a graph we must know what each object reaches, and to walk
/// an app-specific structure (a Numbers sheet's tables, a Keynote slide's placeholders)
/// we can pull an object's direct references without modeling its schema.
///
/// The scan is schema-less: walk every length-delimited field as a candidate
/// sub-message and, whenever a sub-message carries an `identifier` (`#1` varint) that
/// matches a known object id, record it as a reference. Restricting to *known* ids is
/// what makes this exact rather than heuristic — object ids live in a high, sparse
/// range (~1.7M in a blank document), so a stray varint elsewhere in the tree
/// effectively never collides with a real id. Validated by reproducing Apple's stored
/// `object_references` for every object in the blank template.
public enum IWAReferenceScanner {
	/// The object ids referenced anywhere in `payload`, restricted to ids in `known`,
	/// in first-seen order (deduplicated). This is a *complete* set — validated to
	/// never miss a reference Apple records in `object_references` across the blank
	/// template (it's a superset: Apple additionally omits some style/back-pointer
	/// references that it resolves through the stylesheet, which is safe to include
	/// since the targets exist). Use it to compute `#5` for synthesized objects, to
	/// drive reachability, and to read an object's direct children; for unchanged
	/// objects, prefer preserving the original `#5`.
	public static func referencedObjectIDs(in payload: [UInt8], known: Set<UInt64>) -> [UInt64] {
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
