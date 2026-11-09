#if os(macOS) || os(iOS)
import Testing
@testable import SwiftTextHTML

@Suite("Blank pages for left/right starts")
struct PDFParityPagesTests {
	@Test("A right start on an even page gets a blank page, and the shift is carried forward")
	func rightStartsShiftLaterPages() {
		// Chapters printed on pages 0, 1, 2: the second would be page 2 after one blank, the third page 4 after two.
		let plan = PDFParityPages.blankPages(for: [(0, true), (1, true), (2, true)])
		#expect(plan.before == [1, 2])
		#expect(plan.indices == [1, 3])
	}

	@Test("Blocks already on the right side add nothing")
	func correctParityAddsNothing() {
		let plan = PDFParityPages.blankPages(for: [(0, true), (2, true), (3, false)])
		#expect(plan.before.isEmpty)
	}

	@Test("A left start on the first page gets a blank first page")
	func leftStartAtTopOfDocument() {
		let plan = PDFParityPages.blankPages(for: [(0, false)])
		#expect(plan.before == [0])
		#expect(plan.indices == [0])
	}

	@Test("The first block on a page decides for it")
	func firstRequestOnAPageWins() {
		let plan = PDFParityPages.blankPages(for: [(1, true), (1, false)])
		#expect(plan.before == [1])
	}
}
#endif
