#if os(macOS)
import AppKit
import PDFKit
import SwiftTextHTML

/// Stamps searchable text after WebKit has settled the page count. Links are
/// rebuilt because drawing a CGPDFPage copies content, not annotations.
enum PDFPageFurniture {
	static func add(to data: Data, pageNumbers: Bool, title: String?, headings: [PDFChapterHeading], titleSection: (start: PDFChapterHeading, end: PDFChapterHeading?)? = nil) throws -> Data {
		guard pageNumbers || title != nil else { return data }
		guard let source = PDFDocument(data: data) else { throw WebKitBrowserError.printFailed }
		var chapters: [Int: String] = [:]
		for heading in headings {
			let matches = source.findString(heading.searchText, withOptions: [])
			guard heading.occurrence < matches.count, let page = matches[heading.occurrence].pages.first else { continue }
			// When several chapters start on one page, the last one is current.
			chapters[source.index(for: page)] = heading.title
		}
		// The generated title section may span several pages, or follow a page the
		// authored CSS inserted, so its range comes from where it actually lands.
		func page(of heading: PDFChapterHeading) -> Int? {
			let matches = source.findString(heading.searchText, withOptions: [])
			guard heading.occurrence < matches.count, let page = matches[heading.occurrence].pages.first else { return nil }
			return source.index(for: page)
		}
		var bare = 0..<0
		if let titleSection, let start = page(of: titleSection.start) {
			let end = titleSection.end.flatMap { page(of: $0) } ?? source.pageCount
			bare = start..<max(start + 1, end)
		}
		let output = NSMutableData()
		guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
			throw WebKitBrowserError.printFailed
		}
		let links = internalLinks(in: source)
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
			chapter = chapters[index] ?? chapter
			NSGraphicsContext.saveGraphicsState()
			NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
			let furnished = !bare.contains(index)
			if pageNumbers, furnished {
				draw(String(index + 1), in: CGRect(x: bounds.minX + 24, y: bounds.minY + 24, width: bounds.width - 48, height: 14), alignment: .center)
			}
			if let title, furnished {
				let width = (bounds.width - 72) / 2
				draw(title, in: CGRect(x: bounds.minX + 24, y: bounds.maxY - 36, width: width, height: 14), alignment: .left)
				draw(chapter, in: CGRect(x: bounds.midX + 12, y: bounds.maxY - 36, width: width, height: 14), alignment: .right)
			}
			NSGraphicsContext.restoreGraphicsState()
			context.endPage()
		}
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
#endif
