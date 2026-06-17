import Foundation
import Testing
@testable import SwiftTextPages

/// The package layer can disassemble a complete iWork document into framing-preserving
/// records and reassemble a valid package — verbatim, and with every modeled object
/// re-encoded through its generated typed model. This is the read→model→write
/// foundation for cold synthesis. (Both outputs were also confirmed to open in Pages.)
@Suite("IWA package round-trip")
struct IWAPackageTests {
	private func blankEntries() -> [(path: String, bytes: [UInt8])] {
		let t = PagesTemplate.blank
		return t.entries.compactMap { e in t.data(for: e.path).map { (e.path, $0) } }
	}
	private func census(_ entries: [(path: String, bytes: [UInt8])]) -> [UInt64: Int] {
		var c = [UInt64: Int]()
		for e in entries where e.path.hasPrefix("Index/") && e.path.hasSuffix(".iwa") {
			if let objs = try? IWAArchive.objects(from: Data(e.bytes)) { for o in objs { c[o.type, default: 0] += 1 } }
		}
		return c
	}
	private func census(at url: URL) throws -> [UInt64: Int] {
		var c = [UInt64: Int]()
		for e in try PagesContainer.entries(at: url, prefix: "Index/", suffix: ".iwa") {
			if let objs = try? IWAArchive.objects(from: e.data) { for o in objs { c[o.type, default: 0] += 1 } }
		}
		return c
	}

	@Test("verbatim disassemble/reassemble preserves every object")
	func verbatim() throws {
		let entries = blankEntries()
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("pkg-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		try IWAPackage.read(entries).write(to: url)
		#expect(try census(at: url) == census(entries))
	}

	@Test("re-encoding every modeled object through its typed model preserves the document")
	func throughModels() throws {
		let entries = blankEntries()
		var pkg = IWAPackage.read(entries)
		pkg.reencodeThroughModels()
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("pkg-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }
		try pkg.write(to: url)
		#expect(try census(at: url) == census(entries))   // same object graph
		_ = try PagesFile(url: url).markdown()             // still a readable Pages document
	}
}
