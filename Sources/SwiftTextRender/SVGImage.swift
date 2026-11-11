//  SVGImage.swift
//  SwiftTextRender
//
//  Draws a parsed `SVGTree` as vector content: a Form XObject whose `/BBox` is
//  the unit square, like the raster Image XObjects `Painter.drawImage` maps
//  onto the box with its CTM. The view box (and `preserveAspectRatio`) is
//  mapped into the SVG's intrinsic size, then scaled down to the unit square.

import Foundation
import SwiftTextPDFWriter

enum SVGImage {

	/// `true` if `data` looks like an SVG document, so it is worth parsing.
	static func looksLikeSVG(_ data: Data) -> Bool {
		let head = String(decoding: data.prefix(2048), as: UTF8.self)
		return head.contains("<svg")
	}

	/// Decode SVG file bytes into a vector image, or `nil` if they are not a usable SVG.
	static func decode(_ data: Data) -> DecodedImage? {
		guard looksLikeSVG(data), let tree = SVGTree(data: data) else { return nil }
		let width = max(1, Int(tree.width.rounded()))
		let height = max(1, Int(tree.height.rounded()))
		return DecodedImage(width: width, height: height, pdfStream: formXObject(for: tree, width: width, height: height))
	}

	private static func formXObject(for tree: SVGTree, width: Int, height: Int) -> PDFStream {
		let content = PDFStream()
		var graphicsStates: [String: String] = [:]
		let stateResources = PDFDictionary()

		func state(fill: Double, stroke: Double) -> String? {
			guard fill < 1 || stroke < 1 else { return nil }
			let key = "\(formatPDFReal(fill)) \(formatPDFReal(stroke))"
			if let name = graphicsStates[key] { return name }
			let name = "GS\(graphicsStates.count + 1)"
			graphicsStates[key] = name
			stateResources[name] = PDFDictionary([("Type", "/ExtGState"), ("ca", fill), ("CA", stroke)])
			return name
		}

		func emit(_ node: SVGNode) {
			switch node {
			case .group(let matrix, let children):
				content.pushState()
				if matrix != .identity { content.setMatrix(matrix.a, matrix.b, matrix.c, matrix.d, matrix.e, matrix.f) }
				children.forEach(emit)
				content.popState()
			case .path(let path):
				func trace() {
					for segment in path.segments {
						switch segment {
						case .move(let x, let y): content.moveTo(x, y)
						case .line(let x, let y): content.lineTo(x, y)
						case .cubic(let x1, let y1, let x2, let y2, let x, let y): content.curveTo(x1, y1, x2, y2, x, y)
						case .close: content.close()
						}
					}
				}
				func applyStroke(_ stroke: SVGStroke) {
					content.setColorRGB(stroke.color.red, stroke.color.green, stroke.color.blue, stroke: true)
					content.setLineWidth(stroke.width)
					content.setLineCap(stroke.cap)
					content.setLineJoin(stroke.join)
					content.setMiterLimit(stroke.miterLimit)
					if !stroke.dashes.isEmpty {
						// An odd-length dash array repeats to make an even one.
						let dashes = stroke.dashes.count % 2 == 0 ? stroke.dashes : stroke.dashes + stroke.dashes
						content.setDash(dashes, phase: stroke.dashOffset)
					}
				}
				content.pushState()
				if let fill = path.fill, let stroke = path.stroke, fill.opacity == stroke.opacity {
					if let name = state(fill: fill.opacity, stroke: stroke.opacity) { content.setState(name) }
					content.setColorRGB(fill.color.red, fill.color.green, fill.color.blue)
					applyStroke(stroke)
					trace()
					content.fillAndStroke(evenOdd: fill.evenOdd)
				} else {
					if let fill = path.fill {
						if let name = state(fill: fill.opacity, stroke: 1) { content.setState(name) }
						content.setColorRGB(fill.color.red, fill.color.green, fill.color.blue)
						trace()
						content.fill(evenOdd: fill.evenOdd)
					}
					if let stroke = path.stroke {
						if let name = state(fill: 1, stroke: stroke.opacity) { content.setState(name) }
						applyStroke(stroke)
						trace()
						content.stroke()
					}
				}
				content.popState()
			}
		}

		// User space (y down) → viewport pixels → unit square (y up).
		let matrix = tree.viewBoxTransform.then(SVGMatrix(a: 1 / Double(width), d: -1 / Double(height), f: 1))
		content.pushState()
		content.setMatrix(matrix.a, matrix.b, matrix.c, matrix.d, matrix.e, matrix.f)
		tree.children.forEach(emit)
		content.popState()

		var extra: [(String, PDFValue)] = [
			("Type", "/XObject"),
			("Subtype", "/Form"),
			("BBox", PDFArray([0, 0, 1, 1]))
		]
		if !stateResources.isEmpty { extra.append(("Resources", PDFDictionary([("ExtGState", stateResources)]))) }
		for (key, value) in extra { content.setExtra(key, value) }
		return content
	}
}
