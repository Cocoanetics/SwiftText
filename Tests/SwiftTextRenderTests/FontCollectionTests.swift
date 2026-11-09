//  FontCollectionTests.swift
//  SwiftTextRenderTests
//
//  A `.ttc` in `@font-face` or `--font` registers every face, so bold and
//  italic text is set in the matching face of the collection.

import Foundation
import Testing
@testable import SwiftTextRender
import SwiftTextCSS
import SwiftTextOpenType

@Suite("Font collections")
struct FontCollectionTests {
	private static func u16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
	private static func u32(_ value: Int) -> [UInt8] { u16(value >> 16) + u16(value & 0xFFFF) }

	/// A tiny TrueType font collection (`A`, `B`, space) whose faces share every
	/// table but `OS/2` and `name`: regular, bold and italic.
	static func makeCollection() -> Data {
		let head = u16(1) + u16(0) + u32(0) + u32(0) + u32(0x5F0F3CF5) + u16(0) + u16(1000)
			+ u32(0) + u32(0) + u32(0) + u32(0) + u16(0) + u16(0xFFFF - 199) + u16(1000) + u16(800)
			+ u16(0) + u16(0) + u16(0) + u16(1) + u16(0)
		let hhea = u16(1) + u16(0) + u16(800) + u16(0xFFFF - 199) + u16(0) + u16(0)
			+ [UInt8](repeating: 0, count: 22) + u16(4)
		let maxp = u32(0x00010000) + u16(4)
		let hmtx = u16(500) + u16(0) + u16(600) + u16(0) + u16(700) + u16(0) + u16(250) + u16(0)
		let sub = u16(4) + u16(32) + u16(0) + u16(4) + u16(4) + u16(1) + u16(0)
			+ u16(0x41) + u16(0xFFFF) + u16(0) + u16(0x20) + u16(0xFFFF)
			+ u16(0xFFFF - 28) + u16(1) + u16(0) + u16(0)
		let cmap = u16(0) + u16(1) + u16(3) + u16(1) + u32(12) + sub
		let glyph = [UInt8](repeating: 0, count: 10)
		let glyf = glyph + glyph + glyph + glyph
		let loca = u32(0) + u32(10) + u32(20) + u32(30) + u32(40)

		func os2(weight: Int, selection: Int) -> [UInt8] {
			var bytes = [UInt8](repeating: 0, count: 78)
			bytes.replaceSubrange(4 ..< 6, with: u16(weight))
			bytes.replaceSubrange(62 ..< 64, with: u16(selection))
			return bytes
		}
		func nameTable(_ subfamily: String, postScript: String) -> [UInt8] {
			let strings = [(2, subfamily), (1, "Test Serif"), (6, postScript)]
			var records: [UInt8] = [], storage: [UInt8] = []
			for (id, text) in strings.sorted(by: { $0.0 < $1.0 }) {
				let encoded = Array(text.utf16).flatMap { u16(Int($0)) }
				records += u16(3) + u16(1) + u16(0x409) + u16(id) + u16(encoded.count) + u16(storage.count)
				storage += encoded
			}
			return u16(0) + u16(3) + u16(6 + 36) + records + storage
		}
		let shared: [(String, [UInt8])] = [
			("cmap", cmap), ("glyf", glyf), ("head", head), ("hhea", hhea),
			("hmtx", hmtx), ("loca", loca), ("maxp", maxp)
		]
		let faces: [(String, [UInt8], [UInt8])] = [
			("Regular", os2(weight: 400, selection: 0x40), nameTable("Regular", postScript: "TestSerif-Regular")),
			("Bold", os2(weight: 700, selection: 0x20), nameTable("Bold", postScript: "TestSerif-Bold")),
			("Italic", os2(weight: 400, selection: 0x01), nameTable("Italic", postScript: "TestSerif-Italic"))
		]

		// Shared tables are stored once; each face's directory points at them.
		let headerSize = 12 + faces.count * 4
		let directorySize = 12 + 16 * (shared.count + 2)
		var body: [UInt8] = []
		var sharedOffsets: [(String, Int, Int)] = []
		var cursor = headerSize + directorySize * faces.count
		func place(_ bytes: [UInt8]) -> Int {
			let offset = cursor + body.count
			body += bytes
			while body.count % 4 != 0 { body.append(0) }
			return offset
		}
		for (tag, bytes) in shared { sharedOffsets.append((tag, place(bytes), bytes.count)) }
		var directories: [UInt8] = []
		for (_, os2Bytes, nameBytes) in faces {
			var records = sharedOffsets
			records.append(("OS/2", place(os2Bytes), os2Bytes.count))
			records.append(("name", place(nameBytes), nameBytes.count))
			records.sort { $0.0 < $1.0 }
			directories += u32(0x00010000) + u16(records.count) + u16(64) + u16(2) + u16(records.count * 16 - 64)
			for (tag, offset, length) in records { directories += Array(tag.utf8) + u32(0) + u32(offset) + u32(length) }
		}
		var header = Array("ttcf".utf8) + u32(0x00010000) + u32(faces.count)
		for index in 0 ..< faces.count { header += u32(headerSize + directorySize * index) }
		return Data(header + directories + body)
	}

	@Test("The collection reads as three faces with their weight and style")
	func faces() throws {
		let data = Self.makeCollection()
		#expect(OpenTypeFont.faceCount(in: data) == 3)
		let bold = try OpenTypeFont(data: data, fontIndex: 1)
		#expect(bold.weightClass == 700)
		#expect(bold.subfamilyName == "Bold")
		#expect(bold.postScriptName == "TestSerif-Bold")
		let italic = try OpenTypeFont(data: data, fontIndex: 2)
		#expect(italic.isItalic && italic.fsSelection == 1)
	}

	@Test("@font-face with a collection registers bold and italic faces")
	func fontFaceCollection() async throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("collection-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appendingPathComponent("Test Serif.ttc")
		try Self.makeCollection().write(to: url)

		var options = RenderOptions()
		options.compressStreams = false
		let css = "@font-face { font-family: 'Test Serif'; src: url('\(url.absoluteString)'); } body { font-family: 'Test Serif'; }"
		let pdf = try await HTMLRenderer.renderPDF(html: "<p>AB <b>AB</b> <i>AB</i></p>", css: [css], options: options)
		let text = String(decoding: pdf, as: UTF8.self)
		for name in ["TestSerif-Regular", "TestSerif-Bold", "TestSerif-Italic"] {
			#expect(text.contains("/\(name)") || text.contains("+\(name)"), "\(name) is embedded")
		}
	}

	@Test("A declared font-weight narrows the faces a collection registers")
	func declaredWeightNarrows() throws {
		let book = FontBook()
		let faces = try book.registerCollection(data: Self.makeCollection(), family: "Test Serif", bold: true)
		#expect(faces.map(\.postScriptName) == ["TestSerif-Bold"])
	}

	@Test("--font with a collection uses the matching face for bold and italic")
	func overrideCollection() throws {
		let book = FontBook()
		try book.setOverrideFont(data: Self.makeCollection())
		func name(_ weight: Int, _ style: FontStyle) -> String? {
			var computed = ComputedStyle.initial
			computed.fontWeight = weight
			computed.fontStyle = style
			if case .embedded(let font) = book.font(for: computed) { return font.postScriptName }
			return nil
		}
		#expect(name(400, .normal) == "TestSerif-Regular")
		#expect(name(700, .normal) == "TestSerif-Bold")
		#expect(name(400, .italic) == "TestSerif-Italic")
	}
}
