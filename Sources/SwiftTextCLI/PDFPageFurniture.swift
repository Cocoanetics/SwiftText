#if os(macOS)
import AppKit
import PDFKit
import SwiftTextHTML

/// Stamps searchable text and writes the outline after WebKit has settled the page
/// count. Links are rebuilt because drawing a CGPDFPage copies content, not annotations.
enum PDFPageFurniture {
	static func add(to data: Data, pageNumbers: Bool, title: String?, mirrored: Bool = false, numberFromChapter: Bool = false,
	                headings: [PDFChapterHeading], titleSection: (start: PDFChapterHeading, end: PDFChapterHeading?)? = nil,
	                outline: [PDFOutlineBuilder.Entry] = [], blankPages: Set<Int> = []) throws -> Data {
		guard pageNumbers || title != nil || !outline.isEmpty else { return data }
		guard let source = PDFDocument(data: data) else { throw WebKitBrowserError.printFailed }
		let locator = PDFTextLocator(document: source)
		var chapters: [Int: String] = [:]
		for heading in headings {
			guard let found = locator.locate(heading.searchText, occurrence: heading.occurrence) else { continue }
			// When several chapters start on one page, the last one is current.
			chapters[found.pageIndex] = heading.title
		}
		// The generated title section may span several pages, or follow a page the
		// authored CSS inserted, so its range comes from where it actually lands.
		func page(of heading: PDFChapterHeading) -> Int? {
			locator.locate(heading.searchText, occurrence: heading.occurrence)?.pageIndex
		}
		var bare = 0..<0
		if let titleSection, let start = page(of: titleSection.start) {
			// Nothing after the title section means it runs to the end; a successor
			// that cannot be located must not blank the whole document.
			let end = titleSection.end.map { page(of: $0) ?? start + 1 } ?? source.pageCount
			bare = start..<max(start + 1, end)
		}
		let output = NSMutableData()
		guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
			throw WebKitBrowserError.printFailed
		}
		let links = internalLinks(in: source)
		// Pages before the first located chapter get no running head; if no chapter could be located, the title alone is drawn.
		let firstChapter = chapters.keys.filter { !bare.contains($0) }.min() ?? 0
		var chapter = ""
		for index in 0..<source.pageCount {
			guard let page = source.page(at: index), let reference = page.pageRef else { throw WebKitBrowserError.printFailed }
			var bounds = page.bounds(for: .mediaBox)
			context.beginPage(mediaBox: &bounds)
			context.saveGState()
			context.drawPDFPage(reference)
			context.restoreGState()
			for annotation in page.annotations {
				if let url = annotation.url { context.setURL(url as CFURL, for: annotation.bounds) }
			}
			for link in links {
				if link.targetPage == index { context.addDestination(link.name as CFString, at: link.point) }
				if link.sourcePage == index { context.setDestination(link.name as CFString, for: link.bounds) }
			}
			// The title section's own heading is not a chapter: pages before the first real one get no running head.
			if !bare.contains(index) { chapter = chapters[index] ?? chapter }
			NSGraphicsContext.saveGraphicsState()
			NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
			// Blank pages inserted for a left/right chapter start are counted but carry no furniture.
			let furnished = !bare.contains(index) && !blankPages.contains(index)
			// Pages are counted from one, so even indices are the right (odd) pages.
			let isLeft = !index.isMultiple(of: 2)
			if pageNumbers, furnished, !numberFromChapter || index >= firstChapter {
				let number = String(index + 1 - (numberFromChapter ? firstChapter : 0))
				let alignment: NSTextAlignment = mirrored ? (isLeft ? .left : .right) : .center
				draw(number, in: CGRect(x: bounds.minX + 24, y: bounds.minY + 24, width: bounds.width - 48, height: 14), alignment: alignment)
			}
			if let title, furnished, index >= firstChapter, !(mirrored && chapters[index] != nil) {
				let width = (bounds.width - 72) / 2
				if !mirrored || isLeft {
					draw(title, in: CGRect(x: bounds.minX + 24, y: bounds.maxY - 36, width: width, height: 14), alignment: .left)
				}
				if !mirrored || !isLeft {
					draw(chapter, in: CGRect(x: bounds.midX + 12, y: bounds.maxY - 36, width: width, height: 14), alignment: .right)
				}
			}
			NSGraphicsContext.restoreGraphicsState()
			context.endPage()
		}
		// PDFKit drops an `outlineRoot` set on a document read from data when writing it
		// out, but keeps an outline already in the file, so it is written here.
		if let dictionary = PDFOutlineBuilder.dictionary(for: outline) { CGPDFContextSetOutline(context, dictionary) }
		context.closePDF()
		guard let result = PDFDocument(data: output as Data) else { throw WebKitBrowserError.printFailed }
		result.documentAttributes = source.documentAttributes
		guard let resultData = result.dataRepresentation() else { throw WebKitBrowserError.printFailed }
		return resultData
	}

	private static func draw(_ text: String, in rect: CGRect, alignment: NSTextAlignment) {
		let style = NSMutableParagraphStyle()
		style.alignment = alignment
		style.lineBreakMode = .byTruncatingTail
		(text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.darkGray, .paragraphStyle: style])
	}

	private struct InternalLink {
		let name: String
		let sourcePage: Int
		let bounds: CGRect
		let targetPage: Int
		let point: CGPoint
	}

	private static func internalLinks(in source: PDFDocument) -> [InternalLink] {
		var links: [InternalLink] = []
		for index in 0..<source.pageCount {
			guard let page = source.page(at: index) else { continue }
			for annotation in page.annotations {
				guard let destination = (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination,
				      let target = destination.page else { continue }
				links.append(InternalLink(name: "SwiftText-link-\(links.count)", sourcePage: index, bounds: annotation.bounds,
				                          targetPage: source.index(for: target), point: destination.point))
			}
		}
		return links
	}
}

/// The PDF outline (bookmarks) for the webkit engine: every heading, nested by
/// level, as the swift engine writes it.
enum PDFOutlineBuilder {
	struct Entry {
		let level: Int
		let title: String
		let page: Int
		let point: CGPoint
	}

	/// Locates each heading in `data` — the PDF as WebKit printed it, before page
	/// furniture repeats chapter titles in the header. Headings not found are left out.
	static func entries(for headings: [PDFOutlineHeading], in data: Data) -> [Entry] {
		guard !headings.isEmpty, let document = PDFDocument(data: data) else { return [] }
		let locator = PDFTextLocator(document: document)
		return headings.compactMap { heading in
			guard let found = locator.locate(heading.searchText, occurrence: heading.occurrence) else { return nil }
			return Entry(level: heading.level, title: heading.title, page: found.pageIndex, point: CGPoint(x: 0, y: found.bounds.maxY + 4))
		}
	}

	/// The Core Graphics outline: each entry nested under the last one of a higher
	/// level, opening its page at the heading.
	static func dictionary(for entries: [Entry]) -> CFDictionary? {
		guard !entries.isEmpty else { return nil }
		// Children are gathered per entry first, as the dictionaries are values.
		var children: [[Int]] = Array(repeating: [], count: entries.count)
		var roots: [Int] = []
		var stack: [Int] = []
		for (position, entry) in entries.enumerated() {
			while let top = stack.last, entries[top].level >= entry.level { stack.removeLast() }
			if let parent = stack.last { children[parent].append(position) } else { roots.append(position) }
			stack.append(position)
		}
		func item(_ position: Int) -> [String: Any] {
			let entry = entries[position]
			var node: [String: Any] = [kCGPDFOutlineTitle as String: entry.title,
			                           kCGPDFOutlineDestination as String: entry.page + 1,
			                           kCGPDFOutlineDestinationRect as String: CGRect(origin: entry.point, size: .zero).dictionaryRepresentation]
			if !children[position].isEmpty { node[kCGPDFOutlineChildren as String] = children[position].map(item) }
			return node
		}
		return [kCGPDFOutlineChildren as String: roots.map(item)] as CFDictionary
	}
}
#endif
