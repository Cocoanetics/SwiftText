import Foundation
import Testing

@testable import SwiftTextPages

/// Tests for the write side: the Protobuf encoder and the IWA file writer. These
/// are the foundation for writing `.pages` documents; everything here round-trips
/// against the existing reader (`ProtobufMessage`, `IWAArchive`) with no Pages
/// involvement, and uses synthetic fixtures only.
@Suite("IWA / Protobuf writing")
struct IWAWriteTests {
	// MARK: Protobuf encoder

	@Test("ProtobufWriter fields decode back through ProtobufMessage")
	func protobufRoundTrip() {
		var writer = ProtobufWriter()
		writer.varintField(1, 2001)
		writer.stringField(3, "Hello, Pages")
		writer.fixed32Field(5, Float(12.5).bitPattern)
		writer.packedVarintField(7, [10, 20, 300_000])
		var nested = ProtobufWriter()
		nested.varintField(1, 42)
		writer.messageField(9, nested.bytes)

		let message = ProtobufMessage(writer.bytes)
		#expect(message.varint(1) == 2001)
		#expect(message.bytes(3).map { String(decoding: $0, as: UTF8.self) } == "Hello, Pages")
		#expect(message.float(5) == 12.5)
		#expect(message.message(9)?.varint(1) == 42)
		// Packed repeated varints decode as one length-delimited payload of varints.
		#expect(message.bytes(7) == ProtobufWriter.varint(10) + ProtobufWriter.varint(20) + ProtobufWriter.varint(300_000))
	}

	@Test("Varint encoding matches the reader's decoding for boundary values")
	func varintBoundaries() {
		for value: UInt64 in [0, 1, 127, 128, 16_383, 16_384, 1 << 32, .max] {
			var writer = ProtobufWriter()
			writer.varintField(1, value)
			#expect(ProtobufMessage(writer.bytes).varint(1) == value)
		}
	}

	// MARK: IWA object framing

	@Test("Objects round-trip through encode and back")
	func objectRoundTrip() throws {
		let objects = [
			IWAObject(identifier: 1, type: 10000, payload: Array("root".utf8)),
			IWAObject(identifier: 1732539, type: 2001, payload: []),            // empty payload
			IWAObject(identifier: 1732540, type: 2001, payload: Array("body text".utf8)),
		]
		let decoded = try IWAArchive.objects(from: IWAArchive.encode(objects))
		#expect(decoded.count == objects.count)
		for (written, read) in zip(objects, decoded) {
			#expect(read.identifier == written.identifier)
			#expect(read.type == written.type)
			#expect(read.payload == written.payload)
		}
	}

	@Test("Objects sharing an identifier survive the round-trip in order")
	func repeatedIdentifierRoundTrip() throws {
		// iWork stores some identifiers with two payloads (e.g. the 6247 pairs in a
		// real Document.iwa); separate records with the same id read back the same.
		let objects = [
			IWAObject(identifier: 1732619, type: 6247, payload: Array(repeating: 0xAB, count: 226)),
			IWAObject(identifier: 1732619, type: 6247, payload: Array(repeating: 0xCD, count: 68)),
		]
		let decoded = try IWAArchive.objects(from: IWAArchive.encode(objects))
		#expect(decoded.map(\.type) == [6247, 6247])
		#expect(decoded.map(\.payload.count) == [226, 68])
		#expect(decoded.allSatisfy { $0.identifier == 1732619 })
	}

	// MARK: Snappy chunk framing

	@Test("A record stream re-emits and decompresses back unchanged")
	func streamVerbatimRoundTrip() throws {
		// The generator's core operation: capture a decompressed component stream,
		// re-emit it, and get identical bytes back. Use >64 KiB to span chunks.
		var state: UInt64 = 0x9E37_79B9_7F4A_7C15
		var stream = Array("iwa record stream ".utf8)
		for _ in 0..<200_000 {
			state = state &* 6364136223846793005 &+ 1442695040888963407
			stream.append(UInt8((state >> 33) & 0xFF))
		}
		let reDecoded = try IWAArchive.decompress(IWAArchive.encode(stream: stream))
		#expect(reDecoded == stream)
	}

	@Test("Chunk header is a 0x00 flag plus a 24-bit little-endian compressed length")
	func chunkHeaderShape() {
		let stream = Array("a short stream".utf8)
		let file = [UInt8](IWAArchive.encode(stream: stream))
		#expect(file.first == 0x00)
		let declaredLength = Int(file[1]) | Int(file[2]) << 8 | Int(file[3]) << 16
		#expect(declaredLength == file.count - 4)            // single chunk, header excluded
	}

	@Test("A stream larger than 64 KiB is split into multiple chunks")
	func multipleChunksForLargeStream() {
		// Incompressible data: each ≤64 KiB slice yields one chunk, so >64 KiB ⇒ ≥2.
		var state: UInt64 = 0x2545_F491_4F6C_DD1D
		var stream = [UInt8]()
		for _ in 0..<150_000 {
			state = state &* 6364136223846793005 &+ 1442695040888963407
			stream.append(UInt8((state >> 32) & 0xFF))
		}
		let file = [UInt8](IWAArchive.encode(stream: stream))
		var chunkCount = 0
		var pos = 0
		while pos + 4 <= file.count {
			let length = Int(file[pos + 1]) | Int(file[pos + 2]) << 8 | Int(file[pos + 3]) << 16
			chunkCount += 1
			pos += 4 + length
		}
		#expect(chunkCount >= 3)        // 150 KB / 64 KB ⇒ 3 slices
		#expect(pos == file.count)      // chunks tile the file exactly
	}

	// MARK: Editing one object in place (the body-text injection primitive)

	@Test("replacingPayload swaps one object and leaves the others intact")
	func replacePayloadRoundTrip() throws {
		let objects = [
			IWAObject(identifier: 10, type: 2001, payload: Array("alpha".utf8)),
			IWAObject(identifier: 20, type: 6247, payload: Array("beta".utf8)),
			IWAObject(identifier: 30, type: 2001, payload: Array("gamma".utf8)),
		]
		let edited = try IWAArchive.replacingPayload(in: IWAArchive.encode(objects), objectID: 20) { _ in
			Array("BETA-REPLACED".utf8)
		}
		let decoded = try IWAArchive.objects(from: edited)
		#expect(decoded.map(\.identifier) == [10, 20, 30])
		#expect(decoded.map(\.type) == [2001, 6247, 2001])
		#expect(decoded.map { String(decoding: $0.payload, as: UTF8.self) } == ["alpha", "BETA-REPLACED", "gamma"])
	}

	@Test("replacingPayload preserves the edited object's other MessageInfo fields")
	func replacePreservesMessageInfoFields() throws {
		// Hand-build a record whose MessageInfo carries object_references (#5) — the
		// reader ignores it, but the writer must not drop it when editing the payload.
		var messageInfo = ProtobufWriter()
		messageInfo.varintField(1, 2001)              // type
		messageInfo.varintField(3, 5)                 // length (to be rewritten)
		messageInfo.packedVarintField(5, [111, 222])  // object_references
		var archiveInfo = ProtobufWriter()
		archiveInfo.varintField(1, 42)
		archiveInfo.messageField(2, messageInfo.bytes)
		var stream = ProtobufWriter.varint(UInt64(archiveInfo.bytes.count))
		stream += archiveInfo.bytes
		stream += Array("hello".utf8)

		let replacement = Array("a considerably longer payload".utf8)
		let edited = try IWAArchive.replacingPayload(in: IWAArchive.encode(stream: stream), objectID: 42) { _ in replacement }

		// Re-read the record's ArchiveInfo → MessageInfo from the edited stream.
		let editedStream = try IWAArchive.decompress(edited)
		var pos = 0
		func varint() -> UInt64 {
			var shift = UInt64(0), result = UInt64(0)
			while pos < editedStream.count { let b = editedStream[pos]; pos += 1; result |= UInt64(b & 0x7F) << shift; if b & 0x80 == 0 { break }; shift += 7 }
			return result
		}
		let archiveInfoLength = Int(varint())
		let ai = ProtobufMessage(Array(editedStream[pos..<pos + archiveInfoLength]))
		let mi = ProtobufMessage(ai.bytes(2)!)
		#expect(mi.varint(1) == 2001)                                    // type preserved
		#expect(mi.varint(3) == UInt64(replacement.count))               // length updated
		#expect(mi.bytes(5) == ProtobufWriter.varint(111) + ProtobufWriter.varint(222)) // refs preserved
	}

	@Test("replacingPayload throws when the object id is absent")
	func replaceMissingObjectThrows() {
		let file = IWAArchive.encode([IWAObject(identifier: 1, type: 2001, payload: [])])
		#expect(throws: IWAArchive.Error.self) {
			_ = try IWAArchive.replacingPayload(in: file, objectID: 999) { $0 }
		}
	}
}
