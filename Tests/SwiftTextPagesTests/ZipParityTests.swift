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

	/// A *directory-style* package (nested `Index.zip` + loose `Metadata/`/previews) reads
	/// and writes back byte-for-byte. Materialized from the bundled blank template, so no
	/// external files are needed; the read→write pair is proven an exact inverse.
	@Test("directory package read → write is byte-identical")
	func directoryPackageRoundTrip() throws {
		let entries = PagesTemplate.blank.entries.compactMap { e -> (path: String, bytes: [UInt8])? in
			PagesTemplate.blank.data(for: e.path).map { (e.path, $0) }
		}
		let dirA = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("parityDirA.pages")
		let dirB = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("parityDirB.pages")
		for d in [dirA, dirB] { try? FileManager.default.removeItem(at: d) }
		defer { for d in [dirA, dirB] { try? FileManager.default.removeItem(at: d) } }

		try IWAPackage.read(entries).writeDirectoryPackage(to: dirA)
		let reread = try #require(IWAPackage.read(directoryPackageAt: dirA))
		try reread.writeDirectoryPackage(to: dirB)

		// Index/* must be inside Index.zip (not loose), and every file must match dirA.
		#expect(FileManager.default.fileExists(atPath: dirA.appendingPathComponent("Index.zip").path))
		func files(_ base: URL) -> [String: [UInt8]] {
			var map = [String: [UInt8]](); let root = base.resolvingSymlinksInPath().path
			for case let u as URL in (FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) ?? .init()) {
				guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
				let p = u.resolvingSymlinksInPath().path
				if p.hasPrefix(root + "/") { map[String(p.dropFirst(root.count + 1))] = (try? [UInt8](Data(contentsOf: u))) ?? [] }
			}
			return map
		}
		let a = files(dirA), b = files(dirB)
		#expect(!a.isEmpty)
		#expect(Set(a.keys) == Set(b.keys))
		for (path, bytes) in a { #expect(b[path] == bytes) }
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

	/// Golden vector: the encoder reproduces Snappy 1.1.9's exact output — the version
	/// Apple's iWork ships. Captured from the compiled reference 1.1.9 binary on a 540-byte
	/// input (a 1024-entry hash table, the small-table path where a table-relative hash
	/// shift previously diverged from Apple). Locks in 1.1.9 byte-fidelity without needing
	/// the external binary.
	@Test("snappy output is byte-identical to reference 1.1.9")
	func snappyMatchesReference119() throws {
		// swiftlint:disable:next line_length
		let inputB64 = "VGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZy4gVGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZy4gVGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZy4gVGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZy4gVGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZy4gVGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZy4gVGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZy4gVGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZy4gVGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZy4gVGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZy4gVGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZy4gVGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZy4g"
		let expectedB64 = "nASwVGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcyBvdmVyIHRoZSBsYXp5IGRvZy4g/i0A/i0A/i0A/i0A/i0A/i0A/i0Aui0A"
		let input = [UInt8](Data(base64Encoded: inputB64)!)
		let expected = [UInt8](Data(base64Encoded: expectedB64)!)
		#expect(Snappy.compress(input) == expected)
		#expect(try Snappy.decompress(Snappy.compress(input)) == input)
	}
}
