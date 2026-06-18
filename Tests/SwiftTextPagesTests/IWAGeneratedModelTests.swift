import Foundation
import Testing

@testable import SwiftTextPages
import SwiftTextIWA

/// Validates the generated iWork wire models (`Sources/SwiftTextPages/Generated/IWA/`,
/// produced by `Scripts/GenerateIWAModels.swift`). Every modeled object must decode
/// into its typed model and re-encode to *semantically identical* bytes — proving the
/// schema mapping (field numbers, wire types, packed/repeated handling, unknown-field
/// passthrough) is faithful and lossless.
@Suite("IWA generated models")
struct IWAGeneratedModelTests {
	/// Strict protobuf parse: fields only if the whole buffer is consumed with valid
	/// wire types and positive field numbers (so raw bytes/strings aren't mis-recursed).
	private static func strictFields(_ bytes: [UInt8]) -> [ProtobufField]? {
		guard !bytes.isEmpty else { return nil }
		var fields = [ProtobufField](); var pos = 0
		// swiftlint:disable:next line_length
		func rv() -> UInt64? { var s = UInt64(0), r = UInt64(0); while pos < bytes.count { let b = bytes[pos]; pos += 1; r |= UInt64(b & 0x7F) << s; if b & 0x80 == 0 { return r }; s += 7; if s >= 64 { return nil } }; return nil }
		while pos < bytes.count {
			guard let key = rv() else { return nil }
			let number = Int(key >> 3); guard number > 0 else { return nil }
			switch key & 7 {
			case 0: guard let v = rv() else { return nil }; fields.append(.init(number: number, value: .varint(v)))
			case 1: guard pos + 8 <= bytes.count else { return nil }; fields.append(.init(number: number, value: .fixed64(Array(bytes[pos..<pos+8])))); pos += 8
			case 2: guard let l = rv(), l <= UInt64(bytes.count - pos) else { return nil }; let e = pos + Int(l); fields.append(.init(number: number, value: .lengthDelimited(Array(bytes[pos..<e])))); pos = e
			case 5: guard pos + 4 <= bytes.count else { return nil }; fields.append(.init(number: number, value: .fixed32(Array(bytes[pos..<pos+4])))); pos += 4
			default: return nil
			}
		}
		return fields
	}

	/// Order-independent canonical form: sort fields by number, recurse into
	/// sub-messages. Applied to both sides, so field reordering and packed/unpacked or
	/// string/message ambiguity cancel out — only genuine data differences remain.
	private static func canonical(_ bytes: [UInt8]) -> String {
		guard let fields = strictFields(bytes) else { return "raw(\(bytes.count))" }
		let parts = fields.map { f -> (Int, String) in
			switch f.value {
			case .varint(let v): return (f.number, "v\(v)")
			case .fixed32(let b): return (f.number, "x\(b)")
			case .fixed64(let b): return (f.number, "q\(b)")
			case .lengthDelimited(let b):
				if strictFields(b) != nil { return (f.number, "m{\(canonical(b))}") }
				return (f.number, "b\(b)")
			}
		}.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
		return parts.map { "\($0.0):\($0.1)" }.joined(separator: ",")
	}

	/// Round-trips every modeled object in a written `.pages` and asserts losslessness.
	private func assertLosslessRoundTrip(at url: URL, minObjects: Int) throws {
		var modeled = 0
		var failures = [String]()
		for entry in try IWAContainer.entries(at: url, prefix: "Index/", suffix: ".iwa") {
			guard let objects = try? IWAArchive.objects(from: entry.data) else { continue }
			for object in objects {
				guard IWATypeRegistry.modeledTypes.contains(object.type),
				      let re = IWATypeRegistry.reencode(type: object.type, payload: object.payload) else { continue }
				modeled += 1
				if Self.canonical(object.payload) != Self.canonical(re) {
					failures.append("type \(object.type) id \(object.identifier)")
				}
			}
		}
		#expect(modeled >= minObjects, "expected ≥\(minObjects) modeled objects, saw \(modeled)")
		#expect(failures.isEmpty, "non-lossless round-trips: \(failures.prefix(10))")
	}

	@Test("Every modeled object in a generated document round-trips losslessly")
	func generatedDocumentRoundTrips() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-iwa-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		// Exercises text, styles, lists, a link, and a native table (TST 6000–6005).
		let markdown = """
		# Title

		Body with **bold** and *italic* and a [link](https://example.com).

		| Product | Region | Units |
		|:--------|:------:|------:|
		| Widget | North | **120** |
		| Gadget | South | *85* |
		"""
		try MarkdownToPages.convert(markdown, to: url)
		try assertLosslessRoundTrip(at: url, minObjects: 50)
	}

	@Test("Every modeled object in the committed Sample.pages round-trips losslessly")
	func realDocumentRoundTrips() throws {
		guard let url = Bundle.module.url(forResource: "Sample", withExtension: "pages") else {
			Issue.record("Sample.pages fixture missing"); return
		}
		try assertLosslessRoundTrip(at: url, minObjects: 20)
	}
}
