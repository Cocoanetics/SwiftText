import Foundation

/// Minimal encoders for building synthetic `.iwa` fixtures in tests.
///
/// These mirror the wire format that ``SwiftTextPages`` reads: Protocol Buffers
/// fields, an all-literal Snappy block (no real compressor needed — the reader
/// only decompresses), and the IWA chunk + ArchiveInfo/MessageInfo framing.
/// Building fixtures in code keeps heading-detection tests deterministic and
/// free of any binary resource.
enum IWAWriter {
	/// One object to place in an `.iwa` file.
	struct Object {
		let identifier: Int
		let type: Int
		let payload: [UInt8]
	}

	// MARK: Protocol Buffers

	static func varint(_ value: Int) -> [UInt8] {
		var v = value
		var out = [UInt8]()
		repeat {
			var byte = UInt8(v & 0x7F)
			v >>= 7
			if v > 0 { byte |= 0x80 }
			out.append(byte)
		} while v > 0
		return out
	}

	static func field(_ number: Int, wire: Int) -> [UInt8] {
		varint(number << 3 | wire)
	}

	static func varintField(_ number: Int, _ value: Int) -> [UInt8] {
		field(number, wire: 0) + varint(value)
	}

	static func bytesField(_ number: Int, _ data: [UInt8]) -> [UInt8] {
		field(number, wire: 2) + varint(data.count) + data
	}

	static func stringField(_ number: Int, _ string: String) -> [UInt8] {
		bytesField(number, Array(string.utf8))
	}

	static func floatField(_ number: Int, _ value: Float) -> [UInt8] {
		let bits = value.bitPattern
		return field(number, wire: 5) + [
			UInt8(bits & 0xFF),
			UInt8((bits >> 8) & 0xFF),
			UInt8((bits >> 16) & 0xFF),
			UInt8((bits >> 24) & 0xFF),
		]
	}

	// MARK: Snappy + IWA framing

	/// Encodes bytes as a single-literal Snappy block (valid input the reader can
	/// decompress, without implementing compression).
	static func snappyLiteralBlock(_ data: [UInt8]) -> [UInt8] {
		var out = varint(data.count)
		let lengthMinusOne = data.count - 1
		if lengthMinusOne < 60 {
			out.append(UInt8(lengthMinusOne << 2))
		} else {
			var value = lengthMinusOne
			var lengthBytes = [UInt8]()
			while value > 0 {
				lengthBytes.append(UInt8(value & 0xFF))
				value >>= 8
			}
			out.append(UInt8((59 + lengthBytes.count) << 2))
			out.append(contentsOf: lengthBytes)
		}
		out.append(contentsOf: data)
		return out
	}

	/// Assembles a complete `.iwa` file (one chunk) from the given objects.
	static func iwaFile(_ objects: [Object]) -> Data {
		var stream = [UInt8]()
		for object in objects {
			let messageInfo = varintField(1, object.type) + varintField(3, object.payload.count)
			let archiveInfo = varintField(1, object.identifier) + bytesField(2, messageInfo)
			stream += varint(archiveInfo.count) + archiveInfo + object.payload
		}
		let block = snappyLiteralBlock(stream)
		var file: [UInt8] = [
			0x00,
			UInt8(block.count & 0xFF),
			UInt8((block.count >> 8) & 0xFF),
			UInt8((block.count >> 16) & 0xFF),
		]
		file += block
		return Data(file)
	}
}
