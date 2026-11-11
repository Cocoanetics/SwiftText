//  SVGImageTests.swift
//  SwiftTextRenderTests

import Foundation
import Testing
@testable import SwiftTextRender
@testable import SwiftTextPDFWriter

@Suite("SVG images")
struct SVGImageTests {

	private let squares = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10" width="100" height="100"><rect width="10" height="10" fill="#fff"/><path fill="#000" d="M1 1h3v3h-3zM6 6h3v3h-3z"/></svg>"##

	// MARK: - Path data

	@Test("Relative and absolute commands, implicit repeats")
	func pathCommands() {
		#expect(SVGPathData.parse("M10 20 L30 40 50 60") == [.move(10, 20), .line(30, 40), .line(50, 60)])
		#expect(SVGPathData.parse("m1 1 2 2 h3 v-1 H0 V0 z") == [
			.move(1, 1), .line(3, 3), .line(6, 3), .line(6, 2), .line(0, 2), .line(0, 0), .close])
	}

	@Test("Compact number syntax")
	func compactNumbers() {
		#expect(SVGPathData.parse("M1.5.5-1-2") == [.move(1.5, 0.5), .line(-1, -2)])
		#expect(SVGPathData.parse("M1e1,2E-1") == [.move(10, 0.2)])
	}

	@Test("Cubic, smooth, quadratic and smooth quadratic curves")
	func curves() {
		#expect(SVGPathData.parse("M0 0C1 1 2 2 3 3S5 5 6 6") == [
			.move(0, 0), .cubic(1, 1, 2, 2, 3, 3), .cubic(4, 4, 5, 5, 6, 6)])
		let quad = SVGPathData.parse("M0 0Q3 0 3 3T6 6")
		#expect(quad.count == 3)
		#expect(quad[1] == .cubic(2, 0, 3, 1, 3, 3))
		#expect(quad[2] == .cubic(3, 5, 4, 6, 6, 6))
	}

	@Test("Arcs become Béziers and accept flags without separators")
	func arcs() throws {
		let segments = SVGPathData.parse("M0 0a5 5 0 1010 0")
		#expect(segments.count == 3) // a half circle → two quarter arcs
		guard case .cubic(_, _, _, _, let x, let y) = try #require(segments.last) else { Issue.record("not a curve"); return }
		#expect(abs(x - 10) < 1e-9 && abs(y) < 1e-9)
		#expect(SVGPathData.parse("M0 0A0 5 0 0 0 4 4") == [.move(0, 0), .line(4, 4)])
	}

	@Test("Malformed data keeps what came before the error")
	func malformedPath() {
		#expect(SVGPathData.parse("M1 1 L2 2 L3") == [.move(1, 1), .line(2, 2)])
		#expect(SVGPathData.parse("L1 1").isEmpty)
	}

	// MARK: - Transforms

	@Test("Transform lists compose left to right")
	func transforms() throws {
		#expect(SVGValues.transform("translate(10 20)") == SVGMatrix(e: 10, f: 20))
		#expect(SVGValues.transform("scale(2)") == SVGMatrix(a: 2, d: 2))
		let combined = try #require(SVGValues.transform("translate(10,0) scale(2)"))
		#expect(combined == SVGMatrix(a: 2, d: 2, e: 10))
		let rotated = try #require(SVGValues.transform("rotate(90 5 5)"))
		#expect(abs(rotated.e - 10) < 1e-9 && abs(rotated.f) < 1e-9 && abs(rotated.b - 1) < 1e-9)
		#expect(SVGValues.transform("matrix(1 0 0 1 3 4)") == SVGMatrix(e: 3, f: 4))
		#expect(abs(try #require(SVGValues.transform("skewX(45)")).c - 1) < 1e-9)
		#expect(SVGValues.transform("bogus(1)") == nil)
	}

	// MARK: - viewBox

	@Test("viewBox and preserveAspectRatio map into the viewport")
	func viewBoxMapping() throws {
		func tree(_ attributes: String) throws -> SVGTree {
			try #require(SVGTree(data: Data(#"<svg xmlns="http://www.w3.org/2000/svg" \#(attributes)/>"#.utf8)))
		}
		let meet = try tree(#"viewBox="0 0 10 5" width="100" height="100""#)
		#expect(meet.viewBoxTransform == SVGMatrix(a: 10, d: 10, f: 25))
		let min = try tree(#"viewBox="0 0 10 5" width="100" height="100" preserveAspectRatio="xMinYMin""#)
		#expect(min.viewBoxTransform == SVGMatrix(a: 10, d: 10))
		let slice = try tree(#"viewBox="0 0 10 5" width="100" height="100" preserveAspectRatio="xMidYMid slice""#)
		#expect(slice.viewBoxTransform == SVGMatrix(a: 20, d: 20, e: -50))
		let none = try tree(#"viewBox="0 0 10 5" width="100" height="100" preserveAspectRatio="none""#)
		#expect(none.viewBoxTransform == SVGMatrix(a: 10, d: 20))
	}

	@Test("Intrinsic size comes from width/height, then viewBox, then 300×150")
	func intrinsicSize() throws {
		func size(_ attributes: String) throws -> (Double, Double) {
			let tree = try #require(SVGTree(data: Data("<svg \(attributes)/>".utf8)))
			return (tree.width, tree.height)
		}
		#expect(try size(#"width="2in" height="1in""#) == (192, 96))
		#expect(try size(#"viewBox="0 0 40 20""#) == (40, 20))
		#expect(try size(#"viewBox="0 0 40 20" width="80""#) == (80, 40))
		#expect(try size("") == (300, 150))
	}

	// MARK: - Parsing

	@Test("Styles, inheritance and colours resolve")
	func styles() throws {
		let svg = """
			<?xml version="1.0"?><!DOCTYPE svg><!-- c --><svg viewBox="0 0 10 10">
			<g fill="red" stroke="#00f" stroke-width="2">
			<rect width="5" height="5" style="fill: rgb(0,255,0); opacity:.5"/>
			<circle r="2" fill="none"/></g></svg>
			"""
		let tree = try #require(SVGTree(data: Data(svg.utf8)))
		guard case .group(_, let nodes) = tree.children[0], case .path(let rect) = nodes[0], case .path(let circle) = nodes[1] else {
			Issue.record("unexpected tree"); return
		}
		#expect(rect.fill?.color == SVGColor(red: 0, green: 1, blue: 0))
		#expect(rect.fill?.opacity == 0.5)
		#expect(rect.stroke?.width == 2)
		#expect(circle.fill == nil)
		#expect(circle.stroke?.color == SVGColor(red: 0, green: 0, blue: 1))
	}

	@Test("Malformed or non-SVG input is rejected")
	func rejectsMalformed() {
		#expect(ImageDecoder.decode(Data("<svg><rect></svg>".utf8)) == nil)
		#expect(ImageDecoder.decode(Data("<html></html>".utf8)) == nil)
		#expect(ImageDecoder.decode(Data("<svg width=".utf8)) == nil)
	}

	@Test("SVG data URIs decode, base64 and percent-encoded")
	func dataURIs() {
		let base64 = "data:image/svg+xml;base64," + Data(squares.utf8).base64EncodedString()
		#expect(ImageDecoder.decode(dataURI: base64)?.width == 100)
		let encoded = "data:image/svg+xml;utf8," + (squares.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
		#expect(ImageDecoder.decode(dataURI: encoded)?.pdfStream != nil)
	}

	// MARK: - Rendering

	@Test("An <img> SVG renders as a vector Form XObject, not a placeholder")
	func rendersVector() async throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-render-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		try Data(squares.utf8).write(to: directory.appendingPathComponent("square.svg"))

		var warnings: [String] = []
		let pdf = try await HTMLRenderer.renderPDF(
			html: #"<h1>SVG test</h1><p><img src="square.svg" alt="Two black squares"></p>"#,
			baseURL: directory,
			options: RenderOptions(compressStreams: false),
			warningHandler: { warnings.append($0) })

		#expect(warnings.isEmpty)
		func contains(_ marker: String) -> Bool { pdf.range(of: Data(marker.utf8)) != nil }
		#expect(contains("/Subtype /Form"))
		#expect(contains("/BBox [0 0 1 1]"))
		#expect(contains("0 0 0 rg"))
		#expect(contains(" l\n") && contains("\nf\n"))
		#expect(!contains("0.9 0.9 0.9 rg"))
	}

	@Test("Opacity is carried by an ExtGState in the form's own resources")
	func opacityState() throws {
		let svg = #"<svg viewBox="0 0 10 10"><rect width="5" height="5" fill-opacity=".5" stroke="red"/></svg>"#
		let image = try #require(ImageDecoder.decode(Data(svg.utf8)))
		let form = try #require(image.pdfStream)
		let text = String(decoding: form.data, as: UTF8.self)
		#expect(text.contains("/ExtGState"))
		#expect(text.contains("/ca 0.5"))
		#expect(text.contains("gs"))
	}
}
