import Foundation
import Testing

@testable import SwiftTextPages

@Suite("Protobuf wire decoding")
struct ProtobufTests {
	@Test("Reads a multi-byte varint field")
	func varintField() {
		// field 1, varint 150 (0x96 0x01).
		let message = ProtobufMessage([0x08, 0x96, 0x01])
		#expect(message.varint(1) == 150)
		#expect(message.varint(2) == nil)
	}

	@Test("Reads a length-delimited string field")
	func stringField() throws {
		// field 3, "abc".
		let message = ProtobufMessage([0x1A, 0x03, 0x61, 0x62, 0x63])
		let bytes = try #require(message.bytes(3))
		#expect(String(decoding: bytes, as: UTF8.self) == "abc")
	}

	@Test("Reads a fixed32 float field")
	func floatField() {
		// field 3, 18.0 little-endian (0x41900000).
		let message = ProtobufMessage([0x1D, 0x00, 0x00, 0x90, 0x41])
		#expect(message.float(3) == 18.0)
	}

	@Test("Collects repeated length-delimited fields in order")
	func repeatedFields() {
		var bytes = IWAWriter.stringField(3, "one")
		bytes += IWAWriter.stringField(3, "two")
		bytes += IWAWriter.stringField(3, "three")
		let message = ProtobufMessage(bytes)
		let chunks = message.allBytes(3).map { String(decoding: $0, as: UTF8.self) }
		#expect(chunks == ["one", "two", "three"])
	}

	@Test("Descends into nested sub-messages")
	func nestedMessage() {
		let inner = IWAWriter.varintField(1, 7) + IWAWriter.floatField(3, 24.0)
		let outer = IWAWriter.bytesField(11, inner)
		let message = ProtobufMessage(outer)
		let child = message.message(11)
		#expect(child?.varint(1) == 7)
		#expect(child?.float(3) == 24.0)
	}

	@Test("Stops cleanly on a truncated field instead of crashing")
	func truncatedInput() {
		// field 3 length-delimited claims 5 bytes but only 2 follow.
		let message = ProtobufMessage([0x1A, 0x05, 0x61, 0x62])
		#expect(message.bytes(3) == nil)
		#expect(message.fields.isEmpty)
	}

	@Test("Does not trap on a corrupt oversized length")
	func oversizedLengthIsRejected() {
		// field 2, length = UInt64.max (a 10-byte varint) — far beyond the buffer.
		// Must degrade gracefully rather than trap converting/adding the length.
		let message = ProtobufMessage([0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
		#expect(message.bytes(2) == nil)
		#expect(message.fields.isEmpty)
	}
}
