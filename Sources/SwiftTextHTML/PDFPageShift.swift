#if os(macOS)
import CoreGraphics
import Foundation
import PDFKit

/// Moves each page's content sideways, which is how `@page :left` and `:right`
/// margins reach a PDF whose pages WebKit laid out against a single set of margins.
enum PDFPageShift {
	/// Redraws every page translated by `shift(pageIndex)` points, keeping its link
	/// annotations (moved along) and its size. Returns `data` untouched when no page moves.
	static func apply(to data: Data, shift: (Int) -> Double) -> Data {
		guard let document = PDFDocument(data: data), (0 ..< document.pageCount).contains(where: { shift($0) != 0 }),
		      let provider = CGDataProvider(data: data as CFData), let source = CGPDFDocument(provider) else { return data }
		let output = NSMutableData()
		guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { return data }
		for index in 0 ..< document.pageCount {
			guard let page = document.page(at: index), let reference = source.page(at: index + 1) else { continue }
			var bounds = page.bounds(for: .mediaBox)
			let dx = shift(index)
			context.beginPage(mediaBox: &bounds)
			context.saveGState()
			context.translateBy(x: dx, y: 0)
			context.drawPDFPage(reference)
			context.restoreGState()
			for annotation in page.annotations {
				var box = annotation.bounds
				box.origin.x += dx
				if let url = annotation.url { context.setURL(url as CFURL, for: box) }
			}
			context.endPage()
		}
		context.closePDF()
		return output as Data
	}
}
#endif
