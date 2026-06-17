import Foundation

/// Derives IWA persistence type-number → message bindings *without a debugger*, by
/// best-fit decode against real documents.
///
/// The shared `TS*` framework types are bound from the vendored registry, but the
/// app-layer types (`TP.*` Pages, `TN.*` Numbers — whose numbers live only in the app's
/// runtime `TSPRegistry`) are not. Since every object carries its type number and we
/// have the schemas, we can recover the binding statically: score each generated message
/// (`IWACatalog`) by how many of an object's fields it models (the rest fall to
/// `unknownFields`), and the message that perfectly and uniquely fits is the type.
enum IWATypeBinder {
	/// Catalog messages scored against `payload`, by modeled ("claimed") field count,
	/// descending. The first entry is the best-fit message.
	static func bestFit(_ payload: [UInt8], catalog: [(name: String, decode: (ProtobufMessage) -> IWAMessage)] = IWACatalog.all()) -> [(name: String, claimed: Int, total: Int)] {
		let message = ProtobufMessage(payload)
		let total = message.fields.count
		var scored = [(name: String, claimed: Int, total: Int)]()
		for candidate in catalog {
			let claimed = total - candidate.decode(message).unknownFields.count
			if claimed > 0 { scored.append((candidate.name, claimed, total)) }
		}
		return scored.sorted { $0.claimed != $1.claimed ? $0.claimed > $1.claimed : $0.name.count < $1.name.count }
	}

	/// Derives confident type-number → message-name bindings from a document's objects,
	/// for types not already in `existing`. A binding is reported only when one message
	/// models *every* field of the object (perfect structural fit) and strictly beats the
	/// runner-up — so structurally-identical messages stay ambiguous rather than guessed.
	static func deriveBindings(from objects: [IWAObject], existing: Set<UInt64>) -> [UInt64: String] {
		let catalog = IWACatalog.all()
		var samples = [UInt64: [[UInt8]]]()
		for object in objects where !existing.contains(object.type) {
			if (samples[object.type]?.count ?? 0) < 4 { samples[object.type, default: []].append(object.payload) }
		}
		var result = [UInt64: String]()
		for (type, payloads) in samples {
			var best: (name: String, claimed: Int, total: Int)?
			var runnerUp = 0
			for candidate in catalog {
				var claimed = 0, total = 0
				for payload in payloads {
					let message = ProtobufMessage(payload)
					total += message.fields.count
					claimed += message.fields.count - candidate.decode(message).unknownFields.count
				}
				if best == nil || claimed > best!.claimed { runnerUp = best?.claimed ?? 0; best = (candidate.name, claimed, total) }
				else if claimed > runnerUp { runnerUp = claimed }
			}
			if let best, best.total > 0, best.claimed == best.total, best.claimed > runnerUp {
				result[type] = best.name
			}
		}
		return result
	}
}
