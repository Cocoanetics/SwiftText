import Foundation
import Testing
@testable import SwiftTextPages

@Suite("ZIP byte parity")
struct ZipParityTests {
	/// `ZipReader` and `StoredZipWriter` are exact inverses: every byte-affecting field
	/// (timestamps, version, the Zip64-style local extra field) survives a round-trip.
	@Test("reader/writer reproduce an archive byte-for-byte")
	func zipReaderWriterRoundTrip() throws {
		var zip = StoredZipWriter()
		// An Index entry (bare) and a Metadata entry with Apple's local Zip64 extra.
		zip.add(path: "Index/Document.iwa", data: Array("payload-bytes".utf8),
		        meta: .init(dosTime: 0x92f8, dosDate: 0x5ccf, versionMadeBy: 0x3e))
		let size: [UInt8] = [0x24, 0, 0, 0, 0, 0, 0, 0]
		zip.add(path: "Metadata/DocumentIdentifier", data: Array("ABCD".utf8),
		        meta: .init(dosTime: 0x92f8, dosDate: 0x5ccf, versionMadeBy: 0x3e,
		                    localExtra: [0x01, 0x00, 0x10, 0x00] + size + size))
		let archive = [UInt8](zip.finish())

		// Read it back and re-emit; the bytes must be identical.
		let entries = try #require(ZipReader.read(archive))
		#expect(entries.count == 2)
		#expect(entries[0].meta.versionMadeBy == 0x3e)
		#expect(entries[1].meta.localExtra.count == 20)
		var rebuilt = StoredZipWriter()
		for e in entries { rebuilt.add(path: e.path, data: e.data, meta: e.meta) }
		#expect([UInt8](rebuilt.finish()) == archive)
	}

	/// Reading a flat `.pages` and writing it back is byte-identical: the ZIP container
	/// metadata is preserved and unchanged `.iwa` components are re-emitted verbatim.
	/// Driven from the bundled blank template (no external files needed).
	@Test("document read(zip:) → write is byte-identical")
	func documentRoundTripIdentical() throws {
		// Materialize the blank template as a flat package once (this is our "real" file).
		let entries = PagesTemplate.blank.entries.compactMap { e -> (path: String, bytes: [UInt8])? in
			PagesTemplate.blank.data(for: e.path).map { (e.path, $0) }
		}
		let fileA = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("parityA.pages")
		let fileB = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("parityB.pages")
		defer { try? FileManager.default.removeItem(at: fileA); try? FileManager.default.removeItem(at: fileB) }
		try IWAPackage.read(entries).write(to: fileA)

		// Now read that flat zip back through the metadata-preserving path and re-emit.
		let bytesA = [UInt8](try Data(contentsOf: fileA))
		let pkg = try #require(IWAPackage.read(zip: bytesA))
		try pkg.write(to: fileB)
		let bytesB = [UInt8](try Data(contentsOf: fileB))
		#expect(bytesA == bytesB)
	}

	/// The faithful Snappy encoder is an exact inverse of the decompressor for arbitrary
	/// content (round-trip correctness, independent of matching Apple's byte choices).
	@Test("snappy compress → decompress is identity")
	func snappyRoundTrip() throws {
		for sample in [Array("".utf8), Array("hello".utf8), Array(repeating: UInt8(0x41), count: 5000),
		               Array((0..<70000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 3)) })] {
			#expect(try Snappy.decompress(Snappy.compress(sample)) == sample)
		}
	}
}
