import Foundation
import Testing
@testable import SwiftTextPages

@Suite("Pages synthesizer (graph-driven)")
struct PagesSynthesizerTests {
	@Test("writes a plain-text document that re-reads with the body text")
	func plainText() throws {
		let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("synth-plain.pages")
		defer { try? FileManager.default.removeItem(at: url) }

		let synth = PagesSynthesizer()
		try synth.write(text: "Hello from cold synthesis.\nA second paragraph.", to: url)

		// The package re-opens and the body text round-trips through the reader.
		let text = try PagesFile(url: url).plainText()
		#expect(text.contains("Hello from cold synthesis."))
		#expect(text.contains("A second paragraph."))
	}

	@Test("the synthesized package is structurally valid: every IWA parses, refs resolve")
	func structurallyValid() throws {
		let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("synth-valid.pages")
		defer { try? FileManager.default.removeItem(at: url) }

		let synth = PagesSynthesizer()
		try synth.write(text: "Validation document.", to: url)

		let entries = try PagesContainer.entries(at: url, prefix: "").map { ($0.path, [UInt8]($0.data)) }
		let graph = IWAObjectGraph.read(IWAPackage.read(entries))
		let known = graph.allIdentifiers
		#expect(known.count > 100)

		// Every object reference resolves to a real object (no dangling ids).
		for component in graph.components {
			for record in component.records {
				for part in record.parts {
					for ref in IWAReferenceScanner.referencedObjectIDs(in: part.payload, known: known) {
						#expect(known.contains(ref))
					}
				}
			}
		}

		// PackageMetadata's high-water mark covers every id in the document.
		let metadata = entries.first { $0.0 == "Index/Metadata.iwa" }
		let metaObjects = try IWAArchive.objects(from: Data(metadata!.1))
		let pkgMeta = metaObjects.first { $0.type == 11006 }
		let lastID = ProtobufMessage(pkgMeta!.payload).varint(1) ?? 0
		#expect(lastID >= (known.max() ?? 0))
	}
}
