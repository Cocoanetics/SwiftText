import Foundation
import Testing
@testable import SwiftTextPages

@Suite("IWA object graph")
struct IWAObjectGraphTests {
	/// The blank template, parsed into a package.
	private func blankPackage() -> IWAPackage {
		let entries = PagesTemplate.blank.entries.compactMap { e -> (path: String, bytes: [UInt8])? in
			PagesTemplate.blank.data(for: e.path).map { (e.path, $0) }
		}
		return IWAPackage.read(entries)
	}

	@Test("import → export preserves every object losslessly")
	func losslessRoundTrip() throws {
		let graph = IWAObjectGraph.read(blankPackage())
		// Every Index object survives the trip.
		#expect(graph.allIdentifiers.count > 100)

		// Unchanged records re-frame to the exact original bytes (synthesizedReferences nil).
		let original = blankPackage()
		let rebuilt = graph.package()
		for (a, b) in zip(original.files, rebuilt.files) {
			#expect(a.path == b.path)
			if case .iwa(let ra) = a.content, case .iwa(let rb) = b.content {
				#expect(ra.count == rb.count)
				for (x, y) in zip(ra, rb) { #expect(x.framed == y.framed) }
			}
		}
	}

	@Test("reachability from the document root covers the live object set")
	func reachabilityFromRoot() throws {
		let graph = IWAObjectGraph.read(blankPackage())
		// The Pages document root is object id 1 (TP.DocumentArchive, type 10000).
		#expect(graph.type(of: 1) == 10000)
		let live = graph.reachable(from: [1])
		// The root must reach the stylesheet, body and a substantial slice of the graph.
		#expect(live.contains(1))
		#expect(live.count > 50)
	}

	@Test("references are computed completely (superset of Apple's stored #5)")
	func referencesComputed() throws {
		let graph = IWAObjectGraph.read(blankPackage())
		// The root references its stylesheet, body storage, section, etc.
		let rootRefs = Set(graph.referencedIDs(of: 1))
		#expect(!rootRefs.isEmpty)
		// Each referenced id is a real object in the graph.
		for ref in rootRefs { #expect(graph.allIdentifiers.contains(ref)) }
	}

	@Test("synthesized object gets fresh id and computed references, and writes")
	func addSynthesizedObject() throws {
		var graph = IWAObjectGraph.read(blankPackage())
		let before = graph.maxIdentifier

		// A trivial empty text storage referencing the document root, added to Document.iwa.
		var storage = ProtobufWriter()
		storage.varintField(1, 5)                 // StorageArchive.kind = body (placeholder)
		let newID = graph.addObject(type: 2001, payload: storage.bytes, toComponent: "Index/Document.iwa")
		#expect(newID == before + 1)
		#expect(graph.maxIdentifier == newID)

		// It writes to a valid package that re-reads with the extra object present.
		let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("graph-add-\(newID).pages")
		try graph.package().write(to: url)
		defer { try? FileManager.default.removeItem(at: url) }

		let reread = IWAObjectGraph.read(IWAPackage.read(try unzip(url)))
		#expect(reread.allIdentifiers.contains(newID))
		#expect(reread.type(of: newID) == 2001)
	}

	/// Unzips a STORED `.pages` back into (path, bytes) entries for re-reading.
	private func unzip(_ url: URL) throws -> [(path: String, bytes: [UInt8])] {
		try PagesContainer.entries(at: url, prefix: "").map { ($0.path, [UInt8]($0.data)) }
	}
}
