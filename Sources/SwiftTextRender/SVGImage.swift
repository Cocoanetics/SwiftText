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
		let scope = Scope()
		// User space (y down) → viewport (the exact, unrounded size) → unit square (y up).
		let matrix = tree.viewBoxTransform.then(SVGMatrix(a: 1 / tree.width, d: -1 / tree.height, f: 1))
		scope.content.pushState()
		scope.content.setMatrix(matrix.a, matrix.b, matrix.c, matrix.d, matrix.e, matrix.f)
		tree.children.forEach(scope.emit)
		scope.content.popState()
		let form = scope.form(bbox: [0, 0, 1, 1], isolated: false)
		return DecodedImage(width: width, height: height, pdfStream: form, dependencies: scope.allForms, link: scope.link)
	}

	/// One content stream with the resources it uses. A group with opacity gets a
	/// scope of its own, which becomes a transparency-group Form XObject.
	private final class Scope {
		let content = PDFStream()
		private let states = PDFDictionary()
		private var stateNames: [String: String] = [:]
		private let formResources = PDFDictionary()
		private var children: [Scope] = []
		private var formStream: PDFStream?

		/// This scope's forms below it, innermost first, so each has a number
		/// before the form that draws it needs a reference.
		var allForms: [PDFStream] { children.flatMap { $0.allForms + [$0.formStream].compactMap { $0 } } }

		/// Fill in the XObject references once every form has an object number.
		func link() {
			guard !children.isEmpty else { return }
			let xobjects = PDFDictionary()
			for (index, child) in children.enumerated() {
				if let stream = child.formStream { xobjects["Fm\(index + 1)"] = stream.reference }
				child.link()
			}
			formResources["XObject"] = xobjects
		}

		func form(bbox: [Double], isolated: Bool) -> PDFStream {
			if !states.isEmpty { formResources["ExtGState"] = states }
			var extra: [(String, PDFValue)] = [
				("Type", "/XObject"),
				("Subtype", "/Form"),
				("BBox", PDFArray(bbox.map { $0 as PDFValue }))
			]
			if isolated { extra.append(("Group", PDFDictionary([("S", "/Transparency"), ("I", "true")]))) }
			// Resources are referenced by name, so they must exist even if filled in later.
			extra.append(("Resources", formResources))
			for (key, value) in extra { content.setExtra(key, value) }
			formStream = content
			return content
		}

		private func state(fill: Double, stroke: Double) -> String? {
			guard fill < 1 || stroke < 1 else { return nil }
			let key = "\(formatPDFReal(fill)) \(formatPDFReal(stroke))"
			if let name = stateNames[key] { return name }
			let name = "GS\(stateNames.count + 1)"
			stateNames[key] = name
			states[name] = PDFDictionary([("Type", "/ExtGState"), ("ca", fill), ("CA", stroke)])
			return name
		}

		func emit(_ node: SVGNode) {
			switch node {
			case .group(let matrix, let opacity, let nodes):
				content.pushState()
				if matrix != .identity { content.setMatrix(matrix.a, matrix.b, matrix.c, matrix.d, matrix.e, matrix.f) }
				if opacity < 1 {
					// Composite the children together, then fade the result as a whole.
					let child = Scope()
					nodes.forEach(child.emit)
					_ = child.form(bbox: [-1e5, -1e5, 1e5, 1e5], isolated: true)
					children.append(child)
					if let name = state(fill: opacity, stroke: opacity) { content.setState(name) }
					content.drawXObject("Fm\(children.count)")
				} else {
					nodes.forEach(emit)
				}
				content.popState()
			case .path(let path):
				emit(path)
			}
		}

		private func emit(_ path: SVGPath) {
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
}
