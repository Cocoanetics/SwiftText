import Foundation

/// A single decoded Protocol Buffers field (wire-format only — no schema).
struct ProtobufField {
	let number: Int
	let value: Value

	enum Value {
		case varint(UInt64)
		case fixed64([UInt8])
		case lengthDelimited([UInt8])
		case fixed32([UInt8])
	}
}

/// A flat list of wire-format fields, with typed accessors.
///
/// iWork payloads are Protocol Buffers messages whose `.proto` schemas are not
/// public, so the reader works purely at the wire level: it walks fields by
/// number and wire type without needing generated types. Repeated fields appear
/// multiple times; `all(_:)` collects them in order.
struct ProtobufMessage {
	let fields: [ProtobufField]

	init(_ bytes: [UInt8]) {
		self.fields = ProtobufMessage.decode(bytes)
	}

	init(_ data: Data) {
		self.init([UInt8](data))
	}

	/// The first varint value for the given field number, if present.
	func varint(_ number: Int) -> UInt64? {
		for field in fields where field.number == number {
			if case .varint(let value) = field.value { return value }
		}
		return nil
	}

	/// The first length-delimited payload for the given field number.
	func bytes(_ number: Int) -> [UInt8]? {
		for field in fields where field.number == number {
			if case .lengthDelimited(let value) = field.value { return value }
		}
		return nil
	}

	/// Every length-delimited payload for the given field number, in order.
	func allBytes(_ number: Int) -> [[UInt8]] {
		var result = [[UInt8]]()
		for field in fields where field.number == number {
			if case .lengthDelimited(let value) = field.value { result.append(value) }
		}
		return result
	}

	/// The first sub-message for the given field number.
	func message(_ number: Int) -> ProtobufMessage? {
		guard let bytes = bytes(number) else { return nil }
		return ProtobufMessage(bytes)
	}

	/// Every sub-message for the given field number, in order.
	func messages(_ number: Int) -> [ProtobufMessage] {
		allBytes(number).map(ProtobufMessage.init)
	}

	/// Every varint value for the given field number, in order (repeated field).
	func allVarints(_ number: Int) -> [UInt64] {
		var result = [UInt64]()
		for field in fields where field.number == number {
			if case .varint(let value) = field.value { result.append(value) }
		}
		return result
	}

	/// The first 32-bit float value (fixed32 wire type) for the given field.
	func float(_ number: Int) -> Float? {
		for field in fields where field.number == number {
			if case .fixed32(let value) = field.value, value.count == 4 {
				let bits = UInt32(value[0]) | UInt32(value[1]) << 8 | UInt32(value[2]) << 16 | UInt32(value[3]) << 24
				return Float(bitPattern: bits)
			}
		}
		return nil
	}

	private static func decode(_ bytes: [UInt8]) -> [ProtobufField] {
		var fields = [ProtobufField]()
		var pos = 0

		func readVarint() -> UInt64? {
			var shift = UInt64(0)
			var result = UInt64(0)
			while pos < bytes.count {
				let byte = bytes[pos]
				pos += 1
				result |= UInt64(byte & 0x7F) << shift
				if byte & 0x80 == 0 { return result }
				shift += 7
				if shift >= 64 { return nil }
			}
			return nil
		}

		while pos < bytes.count {
			guard let key = readVarint() else { break }
			let number = Int(key >> 3)
			let wireType = key & 0x07
			switch wireType {
			case 0:
				guard let value = readVarint() else { return fields }
				fields.append(ProtobufField(number: number, value: .varint(value)))
			case 1:
				guard pos + 8 <= bytes.count else { return fields }
				fields.append(ProtobufField(number: number, value: .fixed64(Array(bytes[pos..<pos + 8]))))
				pos += 8
			case 2:
				guard let length = readVarint() else { return fields }
				// Bound-check against the remaining bytes *before* converting to Int,
				// so a corrupt oversized length can't trap on the conversion/addition.
				guard length <= UInt64(bytes.count - pos) else { return fields }
				let end = pos + Int(length)
				fields.append(ProtobufField(number: number, value: .lengthDelimited(Array(bytes[pos..<end]))))
				pos = end
			case 5:
				guard pos + 4 <= bytes.count else { return fields }
				fields.append(ProtobufField(number: number, value: .fixed32(Array(bytes[pos..<pos + 4]))))
				pos += 4
			default:
				// Groups (wire types 3/4) are obsolete and unused by iWork; stop
				// rather than risk misreading the remainder of the message.
				return fields
			}
		}

		return fields
	}
}
