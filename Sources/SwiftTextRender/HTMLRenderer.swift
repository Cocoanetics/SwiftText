//  HTMLRenderer.swift
//  SwiftTextRender
//
//  The public entry point: parse HTML, resolve styles, build and lay out the
//  box tree, paint it, and assemble a PDF — all cross-platform, with no WebKit.
//
//  This first version renders a single auto-height page (no pagination yet), so
//  the full document is visible for verifying layout. Real @page-sized,
//  paginated output is layered on next.

import Foundation
import SwiftTextHTML
import SwiftTextCSS
import SwiftTextPDFWriter

/// How the document's base writing direction is chosen.
public enum BaseDirection: Sendable {
	/// Detect from the first strong directional character (CSS `dir=auto`).
	case auto
	case leftToRight
	case rightToLeft
}

public struct RenderOptions {
	/// Page width in CSS pixels (default ≈ US Letter, 816px = 8.5in @96dpi).
	public var pageWidthPx: Double
	/// Page height in CSS pixels. `nil` produces a single auto-height page;
	/// otherwise content is paginated to this height (default ≈ US Letter,
	/// 1056px = 11in @96dpi).
	public var pageHeightPx: Double?
	/// The four page margins in CSS pixels; `@page` margins set them per side.
	public var pageMargins: PageMargins
	/// Page margin in CSS pixels applied on all sides. Reads the top margin.
	public var pageMarginPx: Double {
		get { pageMargins.top }
		set { pageMargins = PageMargins(newValue) }
	}
	/// The document base direction. `.auto` (default) detects RTL from content,
	/// which is what makes Markdown (no `dir` markup) render RTL automatically.
	public var baseDirection: BaseDirection
	/// Deflate page content streams (and embedded fonts / CMaps) with
	/// `/FlateDecode`. On by default — it shrinks text-heavy PDFs several-fold.
	/// Disable it to get verbatim, greppable content streams (e.g. in tests that
	/// assert on literal operator bytes).
	public var compressStreams: Bool
	/// Loads the images the document references by URL — `http` and `https`
	/// with URLSession by default (`HTMLRenderer.urlSessionImageLoader`).
	/// Supply your own to resolve other schemes, such as an email's `cid:`
	/// parts, or `nil` to render without touching the network: remote images
	/// then draw as placeholders. Inline `data:` URIs and local files are read
	/// either way.
	public var imageLoader: ImageLoader?
	/// Running strings for margin boxes: `content: string(name)` shows the
	/// entry at the page's index (the last entry past the end), e.g. the current chapter.
	public var pageStrings: [String: [String]] = [:]
	/// A floor for the page margin, in CSS pixels, applied after `@page` rules,
	/// so margin-box content has a strip to sit in.
	public var minimumPageMarginPx: Double = 0
	/// Set the footnote definitions (`<div class="footnote-definition" id="fn-…">`
	/// that an `<a href="#fn-…">` references) at the foot of the page that holds
	/// the reference, below a short rule, instead of where they stand in the
	/// document. A note too long for what is left of the page continues on the next.
	/// Has no effect without a fixed page height.
	public var pageFootnotes = false

	public init(pageWidthPx: Double = 816, pageHeightPx: Double? = 1056, pageMarginPx: Double = 32, baseDirection: BaseDirection = .auto, compressStreams: Bool = true,
	            imageLoader: ImageLoader? = HTMLRenderer.urlSessionImageLoader) {
		self.pageWidthPx = pageWidthPx
		self.pageHeightPx = pageHeightPx
		self.pageMargins = PageMargins(pageMarginPx)
		self.baseDirection = baseDirection
		self.compressStreams = compressStreams
		self.imageLoader = imageLoader
	}
}

public enum RenderError: Error {
	case noDocument
	case noRootBox
}

/// A rendered PDF together with the page each in-document anchor lands on.
public struct RenderedPDF: Sendable {
	/// The PDF bytes.
	public let data: Data
	/// Zero-based page index for every element `id` (and `<a name>`).
	public let anchorPages: [String: Int]
	/// The number of pages written, blank pages included.
	public let pageCount: Int
}

/// Renders HTML (with optional CSS) to a PDF, cross-platform.
public enum HTMLRenderer {

	/// Render an HTML string to PDF bytes.
	///
	/// - Parameters:
	///   - html: The HTML source.
	///   - css: Additional author stylesheets, applied after any `<style>` the
	///     document carries (note: `<style>` extraction is added later; for now
	///     pass author CSS here).
	///   - fonts: A font book; register OpenType fonts on it to embed them and
	///     render arbitrary families/scripts. Defaults to base-14 only.
	///   - baseURL: The directory local image paths are resolved against.
	///   - options: Page geometry, and how images referenced by URL are loaded
	///     (fetched over HTTP by default; see `RenderOptions.imageLoader`).
	///   - title: Optional document title written to the PDF Info dictionary.
	///   - authors: Document authors written to the PDF Info dictionary.
	///   - warningHandler: Receives warnings for images that cannot be rendered.
	///     By default, warnings are written to standard error.
	public static func renderPDF(
		html: String,
		css: [String] = [],
		fonts: FontBook = FontBook(),
		baseURL: URL? = nil,
		options: RenderOptions = RenderOptions(),
		title: String? = nil,
		authors: [String] = [],
		warningHandler: ((String) -> Void)? = nil
	) async throws -> Data {
		try await renderPDFWithAnchors(html: html, css: css, fonts: fonts, baseURL: baseURL, options: options,
		                               title: title, authors: authors, warningHandler: warningHandler).data
	}

	/// Render an HTML string to PDF bytes, also reporting which page each
	/// element `id` (and `<a name>`) lands on.
	///
	/// Takes the same parameters as ``renderPDF(html:css:fonts:baseURL:options:title:authors:warningHandler:)``.
	/// In-document `<a href="#id">` links to a known anchor are written as
	/// internal `/GoTo` destinations; unknown fragments and external URLs stay
	/// `/URI` actions.
	public static func renderPDFWithAnchors(
		html: String,
		css: [String] = [],
		fonts: FontBook = FontBook(),
		baseURL: URL? = nil,
		options: RenderOptions = RenderOptions(),
		title: String? = nil,
		authors: [String] = [],
		warningHandler: ((String) -> Void)? = nil
	) async throws -> RenderedPDF {
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: baseURL)
		guard let root = builder.root else { throw RenderError.noDocument }
		let reportWarning = warningHandler ?? { warning in
			FileHandle.standardError.write(Data("swifttext: warning: \(warning)\n".utf8))
		}

		// Author stylesheets: the document's own <style> elements first, then any
		// sheets supplied by the caller (which therefore win on equal specificity).
		let documentSheets = root.styleSheets()

		// @page rules in the document override the page geometry.
		var options = options
		applyAtPageRules(documentSheets + css, to: &options)
		// Notes at the foot need a fixed page height, which an `@page` size can supply.
		let notesAtFoot = options.pageFootnotes && options.pageHeightPx != nil
		let css = notesAtFoot ? css + [FootnoteSet.css] : css
		let resolver = StyleResolver(authorStyleSheets: documentSheets + css)
		options.pageMargins = options.pageMargins.floored(at: options.minimumPageMarginPx)
		let pageRules = parsePageRules(documentSheets + css)
		registerFontFaces(documentSheets + css, baseURL: baseURL, in: fonts, warn: reportWarning)

		// Resolve the base direction (auto-detect from content for Markdown etc.).
		let baseDirection: Direction
		switch options.baseDirection {
		case .leftToRight: baseDirection = .ltr
		case .rightToLeft: baseDirection = .rtl
		case .auto: baseDirection = Bidi.firstStrongDirection(of: root.text().unicodeScalars) == .rightToLeft ? .rtl : .ltr
		}

		let styled = StyledElement.build(domElement: root, resolver: resolver, baseDirection: baseDirection)
		var loadedImages: LoadedImages = [:]
		if let imageLoader = options.imageLoader {
			loadedImages = await loadImages(referencedBy: styled, baseURL: baseURL, using: imageLoader)
		}
		guard let rootBox = BoxTreeBuilder.build(from: styled, baseURL: baseURL, loadedImages: loadedImages,
		                                         warningHandler: reportWarning) as? BlockBox else { throw RenderError.noRootBox }

		var footnotes = notesAtFoot ? FootnoteSet.extract(from: rootBox, baseURL: baseURL) : FootnoteSet(notes: [])
		let engine = LayoutEngine(fonts: fonts)
		let margin = options.pageMargins.left
		let contentWidth = max(0, options.pageWidthPx - options.pageMargins.horizontal)
		// Lay the document out as a single tall column (origin at column y = 0).
		let columnHeight = engine.layout(root: rootBox, contentWidth: contentWidth, originX: margin, originY: 0)
		var laidOut = ColumnKey(contentWidth: contentWidth, margin: margin)
		// The notes sit in their own columns, laid out at the width of the run being worked on.
		var notesLaidOut: ColumnKey?
		func ensureNotes(_ key: ColumnKey) {
			guard !footnotes.isEmpty, notesLaidOut != key else { return }
			footnotes.layoutNotes(engine: engine, contentWidth: key.contentWidth, originX: key.margin)
			notesLaidOut = key
		}

		// Split the document into runs of pages that share a page box. Without a
		// fixed page height there is a single auto-height page, so no runs.
		let pageStyleRules = parsePageStyleRules(documentSheets + css)
		var runs = options.pageHeightPx == nil
			? [PageRun(kind: .gap(after: nil, before: nil), name: nil, options: options)]
			: pageRuns(in: rootBox, options: options, rules: pageStyleRules)
		func ensureLayout(for run: PageRun) {
			let key = ColumnKey(contentWidth: max(0, run.options.pageWidthPx - run.margins.horizontal), margin: run.margins.left)
			guard key != laidOut else { return }
			_ = engine.layout(root: rootBox, contentWidth: key.contentWidth, originX: key.margin, originY: 0)
			laidOut = key
			footnotes.locateReferences(in: rootBox)
		}
		func range(of run: PageRun) -> (from: Double, to: Double) {
			switch run.kind {
			case .named(let first, let last): return (first.y, last.y + last.height)
			case .gap(let previous, let next): return (previous.map { $0.y + $0.height } ?? 0, next?.y ?? columnHeight)
			}
		}

		// Paginate each run against its own page box, in document order.
		func paginateRuns(skippingEmpty: Bool) -> Int {
			var pageCount = 0
			for index in runs.indices {
				ensureLayout(for: runs[index])
				ensureNotes(ColumnKey(contentWidth: max(0, runs[index].options.pageWidthPx - runs[index].margins.horizontal),
				                      margin: runs[index].margins.left))
				let (from, to) = range(of: runs[index])
				// With no fixed height there is no page boundary for a break to land
				// on, so fragmentation is skipped: a single auto-height page.
				let slices: [PageSlice]
				if let pageHeight = runs[index].options.pageHeightPx {
					slices = paginate(rootBox, from: from, to: to, pageHeightPx: pageHeight, margins: runs[index].margins,
					                  pageOffset: pageCount, skippingEmpty: skippingEmpty, footnotes: footnotes)
				} else {
					slices = [PageSlice(top: 0, bottom: columnHeight, repeatedHeader: nil)]
				}
				guard !slices.isEmpty else { runs[index].isEmpty = true; continue }
				runs[index].slices = slices
				runs[index].firstPage = pageCount
				pageCount += slices.count
				let isLast = index == runs.count - 1
				func inRun(_ y: Double) -> Bool { y >= from - breakEpsilon && (y < to - breakEpsilon || isLast) }
				runs[index].anchors = collectAnchors(rootBox).filter { inRun($0.value) }
				// A note's link lands on the page of its reference, where the note is.
				for reference in footnotes.references where inRun(reference.y) {
					runs[index].anchors[footnotes.notes[reference.note].id] = reference.y
				}
				var headings: [(level: Int, title: String, y: Double)] = []
				collectHeadings(rootBox, into: &headings)
				runs[index].headings = headings.filter { inRun($0.y) }
			}
			return pageCount
		}
		// The first layout of the column was done above; the references come from it.
		footnotes.locateReferences(in: rootBox)
		var totalPages = paginateRuns(skippingEmpty: runs.count > 1)
		if totalPages == 0 {
			runs = [PageRun(kind: .gap(after: nil, before: nil), name: nil, options: options)]
			totalPages = paginateRuns(skippingEmpty: false)
		}
		runs = runs.filter { !$0.isEmpty }

		var anchorNames = Set<String>()
		for run in runs { anchorNames.formUnion(run.anchors.keys) }
		var internalLinks: [(annotation: PDFDictionary, id: String)] = []

		let pdf = PDF()
		if let title, !title.isEmpty {
			pdf.info["Title"] = PDFString(title)
		}
		if !authors.isEmpty {
			pdf.info["Author"] = PDFString(authors.joined(separator: "; "))
		}
		let fontBuilder = FontResourceBuilder(pdf: pdf, compress: options.compressStreams)
		var pageObjects: [PDFDictionary] = []
		for run in runs {
			ensureLayout(for: run)
			ensureNotes(ColumnKey(contentWidth: max(0, run.options.pageWidthPx - run.margins.horizontal), margin: run.margins.left))
			let pageHeightPx = run.pageHeightPx(columnHeight: columnHeight)
			for (offset, slice) in run.slices.enumerated() {
				let pageIndex = run.firstPage + offset
				let shift = pageShift(rules: pageStyleRules, pageIndex: pageIndex, name: run.name, baseMargin: run.margins.left)
				let geometry = PageGeometry(pageWidthPx: run.options.pageWidthPx, pageHeightPx: pageHeightPx,
				                            margins: run.margins, columnTop: slice.top, sliceHeightPx: slice.bottom - slice.top,
				                            contentOffsetPx: slice.repeatedHeader?.reservedHeight ?? 0, offsetXPx: shift)
				let painter = Painter(geometry: geometry, fonts: fonts, builder: fontBuilder, compress: options.compressStreams,
				                      internalAnchors: anchorNames)
				// A blank page inserted to put the next block on the right side of the
				// spread is counted but carries nothing: no content, no running head,
				// no page number.
				if !slice.isBlank && !slice.isNotesOnly {
					painter.paint(rootBox)
				}
				if let header = slice.repeatedHeader {
					painter.paintRepeatedTableHeader(header.box)
				}
				painter.paintFootnotes(slice.footnotes.map { (footnotes.notes[$0.note].box, $0.from, $0.to) },
				                       ruleColor: RGBA(0.4, 0.4, 0.4, 1))
				if !pageRules.isEmpty, !slice.isBlank {
					let marginBoxes = resolveMarginBoxes(pageRules, pageIndex: pageIndex, totalPages: totalPages,
					                                     rootStyle: rootBox.style, rootFontSize: rootBox.style.fontSize,
					                                     pageName: run.name, strings: options.pageStrings)
					painter.paintMarginBoxes(marginBoxes)
				}
				pdf.addObject(painter.stream)
				let page = PDFDictionary([
					("Type", "/Page"),
					("Parent", pdf.pages.reference),
					("MediaBox", PDFArray([0, 0, run.options.pageWidthPx * pxToPt, pageHeightPx * pxToPt])),
					("Contents", painter.stream.reference),
					("Resources", fontBuilder.resourcesReference)
				])
				internalLinks += painter.internalLinks
				let annotations = painter.annotations()
				if !annotations.isEmpty {
					var references: [PDFValue] = []
					for annotation in annotations {
						pdf.addObject(annotation)
						references.append(annotation.reference)
					}
					page["Annots"] = PDFArray(references)
				}
				pdf.addPage(page)
				pageObjects.append(page)
			}
		}
		// Build the shared font objects now that every page's glyph use is known.
		fontBuilder.finalize()

		var anchorPages: [String: Int] = [:]
		var destinations: [String: PDFArray] = [:]
		var outline: [(level: Int, title: String, destination: PDFArray)] = []
		for run in runs {
			let runPages = Array(pageObjects[run.firstPage ..< run.firstPage + run.slices.count])
			let pageHeightPx = run.pageHeightPx(columnHeight: columnHeight)
			func target(_ y: Double) -> (pageIndex: Int, array: PDFArray) {
				destination(forColumnY: y, slices: run.slices, pages: runPages, pageHeightPx: pageHeightPx, margins: run.margins)
			}
			for (id, y) in run.anchors where anchorPages[id] == nil {
				let resolved = target(y)
				anchorPages[id] = run.firstPage + resolved.pageIndex
				destinations[id] = resolved.array
			}
			for heading in run.headings { outline.append((heading.level, heading.title, target(heading.y).array)) }
		}
		addOutline(to: pdf, headings: outline)
		for link in internalLinks {
			guard let array = destinations[link.id] else { continue }
			link.annotation["A"] = PDFDictionary([("S", "/GoTo"), ("D", array)])
		}
		return RenderedPDF(data: pdf.write(), anchorPages: anchorPages, pageCount: pageObjects.count)
	}

	/// The column y of every element carrying an `id` (and of `<a name>`).
	/// An inline element has no geometry of its own, so it maps to the top of
	/// the block that contains it. The first element with a given id wins.
	private static func collectAnchors(_ root: Box) -> [String: Double] {
		var anchors: [String: Double] = [:]
		func record(_ box: Box, y: Double) {
			guard let element = box.element else { return }
			if let id = element.attributeValue("id"), !id.isEmpty, anchors[id] == nil { anchors[id] = y }
			if element.localName == "a", let name = element.attributeValue("name"), !name.isEmpty,
			   anchors[name] == nil { anchors[name] = y }
		}
		func walk(_ box: Box, blockY: Double) {
			var blockY = blockY
			if box is BlockBox { blockY = box.y }
			record(box, y: blockY)
			if let block = box as? BlockBox {
				for child in block.children { walk(child, blockY: blockY) }
			} else if let inline = box as? InlineBox {
				for child in inline.children { walk(child, blockY: blockY) }
			}
		}
		walk(root, blockY: root.y)
		return anchors
	}

	/// The page and `/XYZ` destination for a column y-coordinate. Slices are
	/// half-open, so a y on a page boundary belongs to the page that follows.
	private static func destination(forColumnY y: Double, slices: [PageSlice], pages: [PDFDictionary],
	                                pageHeightPx: Double, margins: PageMargins) -> (pageIndex: Int, array: PDFArray) {
		var pageIndex = slices.count - 1
		for (index, slice) in slices.enumerated() where y >= slice.top - 0.5 && y < slice.bottom - 0.5 {
			pageIndex = index
			break
		}
		let pageY = margins.top + (slices[pageIndex].repeatedHeader?.reservedHeight ?? 0) + (y - slices[pageIndex].top)
		let topPt = (pageHeightPx - pageY) * pxToPt
		return (pageIndex, PDFArray([pages[pageIndex].reference, "/XYZ", margins.left * pxToPt, topPt, "null"]))
	}

	// MARK: - @page rules

	/// Known named page sizes, in CSS pixels (portrait).
	private static let pageSizesPx: [String: (width: Double, height: Double)] = {
		let mm = 96.0 / 25.4, inch = 96.0
		return [
			"a3": (297 * mm, 420 * mm),
			"a4": (210 * mm, 297 * mm),
			"a5": (148 * mm, 210 * mm),
			"b5": (176 * mm, 250 * mm),
			"letter": (8.5 * inch, 11 * inch),
			"legal": (8.5 * inch, 14 * inch)
		]
	}()

	/// Register every `@font-face` whose `src` is a readable local font file, so a
	/// matching `font-family` is drawn with (and embeds) that face.
	private static func registerFontFaces(_ sheets: [String], baseURL: URL?, in fonts: FontBook, warn: (String) -> Void) {
		for sheet in sheets {
			for node in parseStylesheet(sheet, skipComments: true, skipWhitespace: true) {
				guard case .atRule(let rule) = node, rule.lowerAtKeyword == "font-face", let content = rule.content else { continue }
				var family: String?
				var sources: [String] = []
				var bold = false
				var italic = false
				for declaration in parseDeclarations(content) {
					let tokens = declaration.value.filter { !$0.isWhitespaceOrComment }
					switch declaration.lowerName {
					case "font-family":
						family = tokens.compactMap { token -> String? in
							switch token.token {
							case .string(let name), .ident(let name): return name
							default: return nil
							}
						}.joined(separator: " ")
					case "src":
						for token in tokens {
							switch token.token {
							case .url(let url): sources.append(url)
							case .function(let name, let arguments) where name.lowercased() == "url":
								if let first = arguments.first(where: { !$0.isWhitespaceOrComment }), case .string(let url) = first.token {
									sources.append(url)
								}
							default: break
							}
						}
					case "font-weight":
						if case .ident(let ident) = tokens.first?.token { bold = ident.lowercased() == "bold" }
						if case .number(let number, _, _) = tokens.first?.token { bold = number >= 600 }
					case "font-style":
						if case .ident(let ident) = tokens.first?.token { italic = ident.lowercased() != "normal" }
					default: break
					}
				}
				guard let family, !family.isEmpty else { continue }
				var registeredFace = false
				for source in sources {
					// A scheme-less source is a path: relative to the document, or to the working directory without one.
					let url: URL
					if let parsed = URL(string: source), parsed.scheme != nil {
						url = parsed
					} else if let baseURL {
						url = URL(string: source, relativeTo: baseURL)?.absoluteURL ?? URL(fileURLWithPath: source, relativeTo: baseURL)
					} else {
						url = URL(fileURLWithPath: source)
					}
					guard url.isFileURL, let data = try? Data(contentsOf: url) else { continue }
					if (try? fonts.register(data: data, family: family, bold: bold, italic: italic)) != nil {
						registeredFace = true
						break
					}
				}
				if !registeredFace { warn("@font-face \(family): no usable local font file in src") }
			}
		}
	}

	/// Apply the bare `@page { size; margin }` declarations to the render options.
	/// Named and pseudo-class rules never set the document default.
	/// Apply the bare `@page { size; margin }` declarations to the render options.
	/// Named and pseudo-class rules never set the document default.
	private static func applyAtPageRules(_ sheets: [String], to options: inout RenderOptions) {
		for sheet in sheets {
			for node in parseStylesheet(sheet, skipComments: true, skipWhitespace: true) {
				guard case .atRule(let rule) = node, rule.lowerAtKeyword == "page", let content = rule.content,
				      parsePageSelector(rule.prelude).isBare else { continue }
				for declaration in parseDeclarations(content) {
					switch declaration.lowerName {
					case "size": applyPageSize(declaration.value, to: &options)
					case "margin", "margin-top", "margin-right", "margin-bottom", "margin-left": applyPageMargin(declaration, to: &options)
					default: break
					}
				}
			}
		}
	}

	private static func applyPageSize(_ value: [ComponentValue], to options: inout RenderOptions) {
		var landscape = false
		var named: (width: Double, height: Double)?
		var lengths: [Double] = []
		for token in value where !token.isWhitespaceOrComment {
			if case .ident(let ident) = token.token {
				let lower = ident.lowercased()
				if lower == "landscape" { landscape = true } else if lower == "portrait" { continue } else if let size = pageSizesPx[lower] { named = size }
			} else if let length = parseLength([token], fontSize: 16, rootFontSize: 16), case .px(let pixels) = length {
				lengths.append(pixels)
			}
		}

		if let named {
			options.pageWidthPx = landscape ? named.height : named.width
			options.pageHeightPx = landscape ? named.width : named.height
		} else if lengths.count >= 2 {
			options.pageWidthPx = lengths[0]
			options.pageHeightPx = lengths[1]
		} else if lengths.count == 1 {
			options.pageWidthPx = lengths[0]
			options.pageHeightPx = lengths[0]
		}
	}

	/// Apply a `margin` shorthand (one to four values: top, right, bottom, left)
	/// or a `margin-top` ... `margin-left` longhand to the page margins.
	private static func applyPageMargin(_ declaration: Declaration, to options: inout RenderOptions) {
		// An unsupported component (a percentage, `auto`) would shift the others
		// into the wrong positions, so the whole declaration is ignored.
		var lengths: [Double] = []
		for token in declaration.value where !token.isWhitespaceOrComment {
			guard let length = parseLength([token], fontSize: 16, rootFontSize: 16), case .px(let pixels) = length else { return }
			lengths.append(pixels)
		}
		if declaration.lowerName != "margin", lengths.count != 1 { return }
		switch declaration.lowerName {
		case "margin-top": if let first = lengths.first { options.pageMargins.top = first }
		case "margin-right": if let first = lengths.first { options.pageMargins.right = first }
		case "margin-bottom": if let first = lengths.first { options.pageMargins.bottom = first }
		case "margin-left": if let first = lengths.first { options.pageMargins.left = first }
		case "margin":
			switch lengths.count {
			case 1: options.pageMargins = PageMargins(lengths[0])
			case 2: options.pageMargins = PageMargins(top: lengths[0], right: lengths[1], bottom: lengths[0], left: lengths[1])
			case 3: options.pageMargins = PageMargins(top: lengths[0], right: lengths[1], bottom: lengths[2], left: lengths[1])
			case 4: options.pageMargins = PageMargins(top: lengths[0], right: lengths[1], bottom: lengths[2], left: lengths[3])
			default: break
			}
		default: break
		}
	}

	// MARK: - Bookmarks / outline

	/// Build a PDF outline (bookmarks) from the document's heading hierarchy.
	private static func addOutline(to pdf: PDF, headings: [(level: Int, title: String, destination: PDFArray)]) {
		guard !headings.isEmpty else { return }

		// Nest headings by level using a stack of open ancestors.
		// Local PDF-outline node record; its fields travel together.
			// swiftlint:disable:next large_tuple
			var nodes: [(level: Int, title: String, destination: PDFArray, parent: Int?, children: [Int], dict: PDFDictionary)] = []
		var stack: [Int] = []
		for heading in headings {
			while let top = stack.last, nodes[top].level >= heading.level { stack.removeLast() }
			let index = nodes.count
			nodes.append((heading.level, heading.title, heading.destination, stack.last, [], PDFDictionary()))
			if let parent = stack.last { nodes[parent].children.append(index) }
			stack.append(index)
		}

		let outlineRoot = PDFDictionary([("Type", "/Outlines")])
		pdf.addObject(outlineRoot)
		for index in nodes.indices { pdf.addObject(nodes[index].dict) }

		func wire(_ siblings: [Int], parentReference: Data) {
			for (position, index) in siblings.enumerated() {
				let node = nodes[index]
				let dict = node.dict
				dict["Title"] = PDFString(node.title)
				dict["Parent"] = parentReference
				dict["Dest"] = node.destination
				if position > 0 { dict["Prev"] = nodes[siblings[position - 1]].dict.reference }
				if position < siblings.count - 1 { dict["Next"] = nodes[siblings[position + 1]].dict.reference }
				if !node.children.isEmpty {
					dict["First"] = nodes[node.children.first!].dict.reference
					dict["Last"] = nodes[node.children.last!].dict.reference
					dict["Count"] = node.children.count
					wire(node.children, parentReference: dict.reference)
				}
			}
		}

		let roots = nodes.indices.filter { nodes[$0].parent == nil }
		wire(roots, parentReference: outlineRoot.reference)
		outlineRoot["First"] = nodes[roots.first!].dict.reference
		outlineRoot["Last"] = nodes[roots.last!].dict.reference
		outlineRoot["Count"] = roots.count
		pdf.catalog["Outlines"] = outlineRoot.reference
	}

	private static func collectHeadings(_ box: Box, into headings: inout [(level: Int, title: String, y: Double)]) {
		guard let block = box as? BlockBox else { return }
		if let tag = block.element?.localName, tag.count == 2, tag.hasPrefix("h"),
		   let level = Int(tag.dropFirst()), (1 ... 6).contains(level) {
			let title = headingTitle(block)
			if !title.isEmpty { headings.append((level, title, block.y)) }
		}
		if !block.establishesInlineContext {
			for child in block.children { collectHeadings(child, into: &headings) }
		}
	}

	private static func headingTitle(_ box: BlockBox) -> String {
		var words: [String] = []
		func gather(_ box: Box) {
			guard let block = box as? BlockBox else { return }
			// Inline images contribute fragments without text.
			for line in block.lines { for fragment in line.fragments where !fragment.text.isEmpty { words.append(fragment.text) } }
			for child in block.children { gather(child) }
		}
		gather(box)
		return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Page-break information gathered from the laid-out box tree, in column
	/// coordinates.
	private struct BreakPoints {
		/// Where a break is mandatory (`break-before` / `break-after: page`),
		/// with the page it asks for: `.page` for any, `.left` / `.right` for a
		/// specific side.
		var forced: [Double: Break] = [:]
		/// Where a break is possible without splitting a line: block and line edges.
		var candidates: Set<Double> = []
		/// Candidates the author asked us to steer clear of
		/// (`break-before` / `break-after: avoid`).
		var discouraged: Set<Double> = []
		/// Ranges that should not be split (`break-inside: avoid`).
		var atomic: [(top: Double, bottom: Double)] = []
		/// Top of the first thing that actually paints — a non-empty line box or a
		/// replaced image. Used to recognise a forced break that has nothing above
		/// it. `.infinity` when the document renders nothing at all.
		var firstContentY: Double = .infinity
		/// Bottom of the last thing that actually paints. Used to recognise a
		/// forced break with nothing below it.
		var lastContentY: Double = -.infinity
		/// Complete painted fragments that pagination must not clip. Repeated table
		/// headers are used only when the next such fragment still fits below them.
		var contentFragments: [(top: Double, bottom: Double)] = []

		/// Record a mandatory break; a side request outranks a plain page break
		/// at the same position.
		mutating func addForced(_ y: Double, _ kind: Break) {
			if forced[y] == nil || kind != .page { forced[y] = kind }
		}

		/// Keep only what lies within the column range `from ... to`, so one page
		/// run is paginated on its own.
		mutating func restrict(from: Double, to: Double, epsilon: Double) {
			func inside(_ y: Double) -> Bool { y >= from - epsilon && y <= to + epsilon }
			forced = forced.filter { inside($0.key) }
			candidates = candidates.filter(inside)
			candidates.insert(from)
			candidates.insert(to)
			discouraged = discouraged.filter(inside)
			atomic = atomic.filter { inside($0.top) && inside($0.bottom) }
			contentFragments = contentFragments.filter { inside($0.top) && inside($0.bottom) }
			firstContentY = contentFragments.map(\.top).min() ?? .infinity
			lastContentY = contentFragments.map(\.bottom).max() ?? -.infinity
		}

		mutating func noteContent(top: Double, bottom: Double) {
			firstContentY = min(firstContentY, top)
			lastContentY = max(lastContentY, bottom)
			contentFragments.append((top, bottom))
		}
	}

	private struct RepeatedTableHeader {
		let box: BlockBox
		let tableTop: Double
		/// Painted bottom of the table's final row. The table box itself can extend
		/// farther because of padding, border spacing, or an explicit height.
		let lastRowBottom: Double
		let reservedHeight: Double
	}

	/// The horizontal extent a column was laid out at.
	private struct ColumnKey: Equatable {
		let contentWidth: Double
		let margin: Double
	}

	/// A run of consecutive pages that share a page box: either one block that
	/// asked for a named page, or the document flow between two such blocks.
	private struct PageRun {
		enum Kind {
			case named(first: BlockBox, last: BlockBox)
			case gap(after: BlockBox?, before: BlockBox?)
		}

		let kind: Kind
		let name: String?
		/// The page box of the run: size and margin from `@page <name>`, or the document's.
		let options: RenderOptions
		var slices: [PageSlice] = []
		var firstPage = 0
		var isEmpty = false
		var anchors: [String: Double] = [:]
		var headings: [(level: Int, title: String, y: Double)] = []

		init(kind: Kind, name: String?, options: RenderOptions) {
			self.kind = kind
			self.name = name
			self.options = options
		}

		var margins: PageMargins { options.pageMargins }

		func pageHeightPx(columnHeight: Double) -> Double {
			options.pageHeightPx ?? (columnHeight + margins.vertical)
		}
	}

	/// The outermost blocks asking for a named page (`page: <name>`), in document
	/// order. Directly adjacent siblings with the same name form one group, since
	/// a page break is only due where the page name changes.
	private static func namedPageBlocks(in root: BlockBox) -> [(first: BlockBox, last: BlockBox, name: String)] {
		var result: [(first: BlockBox, last: BlockBox, name: String)] = []
		var lastSibling: (parent: ObjectIdentifier, index: Int)?
		func visit(_ box: BlockBox, parent: BlockBox?, index: Int) {
			if let name = box.style.page {
				if let parent, let lastSibling, lastSibling.parent == ObjectIdentifier(parent),
				   lastSibling.index == index - 1, let previous = result.last, previous.name == name {
					result[result.count - 1].last = box
				} else {
					result.append((box, box, name))
				}
				lastSibling = parent.map { (ObjectIdentifier($0), index) }
				return
			}
			guard !box.establishesInlineContext else { return }
			for (childIndex, child) in box.children.enumerated() {
				if let child = child as? BlockBox { visit(child, parent: box, index: childIndex) }
			}
		}
		visit(root, parent: nil, index: 0)
		return result
	}

	/// Split the document into page runs: each `page: <name>` block is a run on
	/// its own pages, and the flow around them is a run with the document's page
	/// box. A name without a size falls back to the document's size.
	private static func pageRuns(in root: BlockBox, options: RenderOptions, rules: [PageStyleRule]) -> [PageRun] {
		var runs: [PageRun] = []
		var previous: BlockBox?
		for (block, last, name) in namedPageBlocks(in: root) {
			runs.append(PageRun(kind: .gap(after: previous, before: block), name: nil, options: options))
			var namedOptions = options
			for rule in rules where rule.selector.name == name && !rule.selector.first
				&& rule.selector.side == nil && !rule.selector.unsupported {
				for declaration in rule.declarations {
					switch declaration.lowerName {
					case "size": applyPageSize(declaration.value, to: &namedOptions)
					case "margin", "margin-top", "margin-right", "margin-bottom", "margin-left": applyPageMargin(declaration, to: &namedOptions)
					default: break
					}
				}
			}
			namedOptions.pageMargins = namedOptions.pageMargins.floored(at: namedOptions.minimumPageMarginPx)
			runs.append(PageRun(kind: .named(first: block, last: last), name: name, options: namedOptions))
			previous = last
		}
		runs.append(PageRun(kind: .gap(after: previous, before: nil), name: nil, options: options))
		return runs
	}

	/// A `@page` rule's geometry declarations (`size`, `margin`, ...) and selector.
	private struct PageStyleRule {
		let selector: PageSelector
		let declarations: [Declaration]
	}

	private static func parsePageStyleRules(_ sheets: [String]) -> [PageStyleRule] {
		var rules: [PageStyleRule] = []
		for sheet in sheets {
			for node in parseStylesheet(sheet, skipComments: true, skipWhitespace: true) {
				guard case .atRule(let rule) = node, rule.lowerAtKeyword == "page", let content = rule.content else { continue }
				rules.append(PageStyleRule(selector: parsePageSelector(rule.prelude), declarations: parseDeclarations(content)))
			}
		}
		return rules
	}

	/// How far a page's content moves sideways because a `:first`, `:left` or
	/// `:right` rule gives it a different left margin than the page box it was
	/// laid out against — mirrored binding margins. The content width stays the
	/// layout's, so a pair of rules should keep left + right equal.
	private static func pageShift(rules: [PageStyleRule], pageIndex: Int, name: String?, baseMargin: Double) -> Double {
		var left: Double?
		let ordered = rules.enumerated()
			.sorted { ($0.element.selector.specificity, $0.offset) < ($1.element.selector.specificity, $1.offset) }
			.map(\.element)
		for rule in ordered where (rule.selector.first || rule.selector.side != nil)
			&& rule.selector.matches(pageIndex: pageIndex, pageName: name) {
			for declaration in rule.declarations {
				let lengths = declaration.value.filter { !$0.isWhitespaceOrComment }.compactMap { token -> Double? in
					guard let length = parseLength([token], fontSize: 16, rootFontSize: 16), case .px(let pixels) = length else { return nil }
					return pixels
				}
				switch declaration.lowerName {
				case "margin-left": if let first = lengths.first { left = first }
				case "margin":
					// One value: all sides; two or three: the second is left and right; four: the fourth is left.
					switch lengths.count {
					case 1: left = lengths[0]
					case 2, 3: left = lengths[1]
					case 4: left = lengths[3]
					default: break
					}
				default: break
				}
			}
		}
		return (left ?? baseMargin) - baseMargin
	}

	private struct PageSlice {
		let top: Double
		let bottom: Double
		let repeatedHeader: RepeatedTableHeader?
		/// An empty page inserted so that a `break-before: left|right` block
		/// starts on the requested side. It spans no column height.
		var isBlank = false
		/// The notes set at the foot of the page, in order.
		var footnotes: [FootnoteChunk] = []
		/// A page of notes that spilled over from the last page of text.
		var isNotesOnly = false

		static func blank(at y: Double) -> PageSlice {
			PageSlice(top: y, bottom: y, repeatedHeader: nil, isBlank: true)
		}
	}

	/// Tolerance for comparing column coordinates, in CSS pixels. Also the floor
	/// on slice height, which keeps the pagination loop moving.
	private static let breakEpsilon = 0.5

	/// Split the laid-out column into page slices, honouring CSS fragmentation
	/// properties and otherwise breaking at line and block boundaries.
	///
	/// Only the column range `from ..< to` is paginated — one page run — and
	/// `pageOffset` is the number of pages before it, which fixes the side the
	/// first page falls on. An empty range yields no slices when `skippingEmpty`.
	private static func paginate(_ root: BlockBox, from: Double, to columnHeight: Double, pageHeightPx: Double, margins: PageMargins,
	                             pageOffset: Int, skippingEmpty: Bool, footnotes: FootnoteSet) -> [PageSlice] {
		let contentHeight = max(1, pageHeightPx - margins.vertical)
		let epsilon = breakEpsilon

		var points = BreakPoints()
		collectBreaks(root, into: &points)
		points.restrict(from: from, to: columnHeight, epsilon: epsilon)
		if skippingEmpty, !points.firstContentY.isFinite { return [] }
		let contentFragments = points.contentFragments.sorted { ($0.top, $0.bottom) < ($1.top, $1.bottom) }
		let tableHeaders = repeatedTableHeaders(in: root).filter { $0.tableTop >= from - epsilon && $0.lastRowBottom <= columnHeight + epsilon }

		// Drop breaks that would only produce a blank page — one with nothing
		// painted above it (the common `h1 { break-before: page }` on a document
		// that opens with an h1) or nothing below it (`break-after` on the last
		// element). Both tests are against painted content rather than against
		// 0 and `columnHeight`, because the body's margins sit outside both.
		//
		// Suppressing the leading blank is a deliberate divergence from the WebKit
		// engine, which emits it. WeasyPrint — which this engine ports —
		// suppresses it, and a blank first page is not what an author asking for
		// "start each chapter on a new page" means.
		//
		// The same goes for two forced breaks with nothing painted between them
		// (`.toc { break-after: page }` followed by `h1 { break-before: page }`):
		// WeasyPrint merges adjacent forced breaks, so only the later one is kept,
		// which starts the next page at the heading's border box.
		//
		// A break that asks for a side (`left` / `right`) is the exception for
		// the leading case: the first page is a right-hand page, so a `left`
		// break at the very top is satisfied by one blank page.
		let inRange = points.forced.keys
			.filter { $0 > points.firstContentY + epsilon && $0 < points.lastContentY - epsilon }
			.sorted()
		var forced: [Double] = []
		var kinds: [Double: Break] = [:]
		for y in inRange {
			var kind = points.forced[y] ?? .page
			if let previous = forced.last,
			   !contentFragments.contains(where: { $0.bottom > previous + epsilon && $0.top < y - epsilon }) {
				// Adjacent breaks merge; the side one of them asked for survives.
				if kind == .page, let earlier = kinds[previous] { kind = earlier }
				kinds[previous] = nil
				forced[forced.count - 1] = y
			} else {
				forced.append(y)
			}
			kinds[y] = kind
		}
		let leadingKinds = points.forced.filter { $0.key <= points.firstContentY + epsilon }.map(\.value)
		let opensRightFirst = pageOffset.isMultiple(of: 2)
		let leadingBlank = points.firstContentY.isFinite
			&& ((opensRightFirst && leadingKinds.contains(.left) && !leadingKinds.contains(.right))
				|| (!opensRightFirst && leadingKinds.contains(.right) && !leadingKinds.contains(.left)))

		// Short documents still need pagination if they carry a forced break.
		let hasNotes = footnotes.references.contains { $0.y >= from - epsilon && $0.y < columnHeight - epsilon }
		guard columnHeight > contentHeight + epsilon || !forced.isEmpty || leadingBlank || hasNotes else {
			return [PageSlice(top: from, bottom: columnHeight, repeatedHeader: nil)]
		}

		// `break-inside: avoid` can only be honoured for blocks that would fit on
		// a page at all; a taller one has to be split regardless.
		let atomic = points.atomic.filter { $0.bottom - $0.top <= contentHeight + epsilon }
		let candidates = points.candidates.sorted()

		func splitsAtomicBlock(_ y: Double) -> Bool {
			atomic.contains { y > $0.top + epsilon && y < $0.bottom - epsilon }
		}

		var slices: [PageSlice] = []
		var top = from
		// What spilled over from the page before: the rest of a note too long to finish there.
		var carry: [FootnoteChunk] = []
		if leadingBlank { slices.append(.blank(at: from)) }
		while top < columnHeight - epsilon {
			// A block that asked for a side starts on that side: one blank page
			// when the page about to open is on the other. Page 1 is a right page.
			if top > from + epsilon, let kind = kinds.first(where: { abs($0.key - top) <= epsilon })?.value {
				let opensRightPage = (pageOffset + slices.count).isMultiple(of: 2)
				if (kind == .right && !opensRightPage) || (kind == .left && opensRightPage) {
					slices.append(.blank(at: top))
				}
			}
			let repeatedHeader = tableHeaders
				.filter { header in
					guard top >= header.box.y + header.box.height - epsilon,
					      top < header.lastRowBottom - epsilon,
					      header.reservedHeight < contentHeight - epsilon else { return false }
					guard let nextFragment = contentFragments.first(where: {
						$0.bottom > top + epsilon && $0.top < header.lastRowBottom - epsilon
					}) else { return false }
					let availableBottom = top + contentHeight - header.reservedHeight
					let fragmentBottomLimit = forced.first {
						$0 > top + epsilon && $0 <= availableBottom + epsilon
					} ?? availableBottom
					return nextFragment.top >= top - epsilon
						&& nextFragment.bottom <= fragmentBottomLimit + epsilon
				}
				.min { ($0.lastRowBottom - $0.tableTop) < ($1.lastRowBottom - $1.tableTop) }
			let reservedHeight = repeatedHeader?.reservedHeight ?? 0
			let room = max(epsilon, contentHeight - reservedHeight)
			let target = top + room

			// The notes a page ending at `bottom` has to carry, and whether the text
			// above `bottom` fits together with them.
			func entries(upTo bottom: Double) -> [FootnoteChunk] {
				footnotes.entries(carry: carry, top: top, bottom: bottom, epsilon: epsilon)
			}
			func fits(_ bottom: Double) -> Bool {
				bottom - top + FootnoteSet.areaHeight(of: entries(upTo: bottom)) <= room + epsilon
			}
			func slice(to bottom: Double, entries: [FootnoteChunk]) -> PageSlice {
				var slice = PageSlice(top: top, bottom: bottom, repeatedHeader: repeatedHeader)
				slice.footnotes = entries
				return slice
			}

			// A mandatory break outranks everything, even when it leaves most of
			// the page empty. The *earliest* one wins: we cannot page past it. It
			// can only be refused when the notes of the lines above it do not fit.
			let forcedBreak = forced.first { $0 > top + epsilon && $0 <= target + epsilon }
			if let forcedBreak, fits(forcedBreak) {
				slices.append(slice(to: forcedBreak, entries: entries(upTo: forcedBreak)))
				carry = []
				top = forcedBreak
				continue
			}

			if forcedBreak == nil, target >= columnHeight, fits(columnHeight) {
				slices.append(slice(to: columnHeight, entries: entries(upTo: columnHeight)))
				carry = []
				break
			}

			// Otherwise take the furthest legal break that fits, relaxing the
			// author's preferences one at a time rather than giving up on them
			// together. The final fallback slices mid-line, which is what has to
			// happen when a single line is taller than the page.
			let ceiling = forcedBreak.map { $0 - epsilon } ?? .infinity
			let reachable = candidates.filter { $0 > top + epsilon && $0 <= target + epsilon && $0 < ceiling }
			// A line moves to the next page, with its notes, when they do not fit together.
			let fitting = reachable.filter(fits)
			let bottom = fitting.last { !splitsAtomicBlock($0) && !points.discouraged.contains($0) }
				?? fitting.last { !splitsAtomicBlock($0) }
				?? fitting.last
				// Not even the first line fits with its notes: it stays, and a note
				// too long for what is left continues on the next page.
				?? reachable.first
				?? target
			let pageNotes = entries(upTo: bottom)
			if fitting.contains(bottom) || pageNotes.isEmpty {
				slices.append(slice(to: bottom, entries: pageNotes))
				carry = []
			} else {
				let noteRoom = room - (bottom - top) - FootnoteSet.separatorHeight
				let (placed, rest) = footnotes.fill(pageNotes, room: noteRoom, force: false, epsilon: epsilon)
				slices.append(slice(to: bottom, entries: placed))
				carry = rest
			}
			top = bottom
		}
		// Notes still spilling after the last line get pages of their own.
		while !carry.isEmpty {
			let (placed, rest) = footnotes.fill(carry, room: contentHeight - FootnoteSet.separatorHeight, force: true, epsilon: epsilon)
			var slice = PageSlice(top: columnHeight, bottom: columnHeight, repeatedHeader: nil)
			slice.footnotes = placed
			slice.isNotesOnly = true
			slices.append(slice)
			carry = rest
		}
		return slices.isEmpty ? [PageSlice(top: from, bottom: columnHeight, repeatedHeader: nil)] : slices
	}

	/// Find header groups that can be reused when their table crosses a page
	/// boundary. The trailing gap is inferred from the first following row so the
	/// repeated header reserves the table's existing border spacing too.
	private static func repeatedTableHeaders(in root: BlockBox) -> [RepeatedTableHeader] {
		var headers: [RepeatedTableHeader] = []
		func visit(_ box: BlockBox) {
			if box.style.display == .table {
				var groups: [BlockBox] = []
				var rows: [BlockBox] = []
				func collectTableChildren(_ parent: BlockBox) {
					for child in parent.children {
						guard let block = child as? BlockBox else { continue }
						if block.style.display == .table { continue }
						if block.style.display == .tableHeaderGroup { groups.append(block) }
						if block.style.display == .tableRow { rows.append(block) }
						collectTableChildren(block)
					}
				}
				collectTableChildren(box)
				let lastRowBottom = rows.map { $0.y + $0.height }.max() ?? box.y
				for group in groups where group.height > 0 {
					let groupBottom = group.y + group.height
					let followingRowTop = rows.lazy.map(\.y).filter { $0 >= groupBottom - breakEpsilon }.min()
					let trailingGap = max(0, (followingRowTop ?? groupBottom) - groupBottom)
					headers.append(RepeatedTableHeader(
						box: group,
						tableTop: box.y,
						lastRowBottom: lastRowBottom,
						reservedHeight: group.height + trailingGap))
				}
			}
			for child in box.children {
				if let block = child as? BlockBox { visit(block) }
			}
		}
		visit(root)
		return headers.filter { $0.reservedHeight < $0.lastRowBottom - $0.tableTop - breakEpsilon }
	}

	/// Whether this box draws anything of its own — a background or a visible
	/// border — independently of its contents.
	private static func paintsDecoration(_ block: BlockBox) -> Bool {
		if let background = block.style.backgroundColor, background.alpha > 0 { return true }
		let border = block.usedBorder
		return border.top > 0 || border.right > 0 || border.bottom > 0 || border.left > 0
	}

	/// Walk the laid-out tree collecting break candidates and the fragmentation
	/// preferences declared on each block.
	private static func collectBreaks(_ box: Box, into points: inout BreakPoints) {
		guard let block = box as? BlockBox else { return }
		let top = block.y
		let bottom = block.y + block.height
		points.candidates.insert(top)
		points.candidates.insert(bottom)

		switch block.style.breakBefore {
		case .page, .left, .right: points.addForced(top, block.style.breakBefore)
		case .avoid: points.discouraged.insert(top)
		case .auto: break
		}
		switch block.style.breakAfter {
		case .page, .left, .right: points.addForced(bottom, block.style.breakAfter)
		case .avoid: points.discouraged.insert(bottom)
		case .auto: break
		}
		if block.style.breakInside == .avoid, block.height > 0 {
			points.atomic.append((top, bottom))
		}

		if block.image != nil {
			points.noteContent(top: top, bottom: bottom)
		} else if block.children.isEmpty, block.lines.isEmpty, block.height > 0, paintsDecoration(block) {
			// A box with nothing in it but a background or border still fills its
			// page, so a break after it is not a blank-page break. The emptiness
			// test matters: a background on a box that *contains* the content is
			// decoration around it, not content itself, and counting it would let
			// any `body { background: … }` defeat blank-page suppression.
			points.noteContent(top: top, bottom: bottom)
		}

		if block.establishesInlineContext {
			for line in block.lines {
				points.candidates.insert(line.y)
				points.candidates.insert(line.y + line.height)
				if !line.fragments.isEmpty {
					points.noteContent(top: line.y, bottom: line.y + line.height)
				}
			}
		} else {
			var keepWithNext = false
			for child in block.children {
				if keepWithNext, let next = child as? BlockBox {
					// A `break-after: avoid` box (every heading) stays with the start of
					// whatever follows — list, table, quote, code, image — so the edges
					// at the top of that block and of its first descendants are
					// discouraged too, not only the heading's own bottom edge.
					discourageLeadingEdges(of: next, into: &points)
				}
				collectBreaks(child, into: &points)
				keepWithNext = (child as? BlockBox)?.style.breakAfter == .avoid
			}
		}
	}

	/// Discourage a break at the top of `block` and of each first child below it,
	/// which all share (or nearly share) the edge that follows a kept-with-next box.
	private static func discourageLeadingEdges(of block: BlockBox, into points: inout BreakPoints) {
		points.discouraged.insert(block.y)
		// Padding or a border can put the first line's edge below the block's own.
		if block.establishesInlineContext, let line = block.lines.first {
			points.discouraged.insert(line.y)
		}
		guard !block.establishesInlineContext,
		      let first = block.children.compactMap({ $0 as? BlockBox }).first else { return }
		discourageLeadingEdges(of: first, into: &points)
	}

}
