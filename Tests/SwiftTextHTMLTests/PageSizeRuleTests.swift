import Testing
@testable import SwiftTextHTML

@Suite("PageSizeRule")
struct PageSizeRuleTests {
	@Test("only a bare @page rule sets the document size")
	func bareOnly() {
		let css = "@page wide { size: A3; } @page :first { size: A5; } @page :left { size: letter; }"
		#expect(PageSizeRule.pointSize(in: css) == nil)
		let size = PageSizeRule.pointSize(in: "@page wide { size: A3; } @page { size: A5; } @page :first { size: A3; }")
		#expect(Int((size?.width ?? 0) / 72 * 25.4 + 0.5) == 148)
	}

	@Test("named pages carry their size and margins")
	func namedPages() {
		let pages = PageSizeRule.namedPages(in: "@page wide { size: A4 landscape; margin-left: 10mm } @page :first { size: A3 } .x { page: wide }",
		                                   fallback: (595, 842))
		#expect(pages.map(\.name) == ["wide"])
		#expect(Int((pages[0].size?.width ?? 0).rounded()) == 842)
		#expect(pages[0].margins.map(\.name) == ["margin-left"])
	}

	@Test("page assignments keep auto and importance, and only print-applicable groups")
	func assignments() {
		let found = PageSizeRule.pageAssignments(in: ".wide, .big { page: wide; color: red } p { page: auto } @media print { .a { page: a !important } } @media screen { .s { page: s } }")
		#expect(found.map(\.selector) == [".wide, .big", "p", ".a"])
		#expect(found.map(\.name) == ["wide", "auto", "a"])
		#expect(found.map(\.important) == [false, false, true])
	}

	@Test("statement at-rules before a rule do not hide its page assignment")
	func assignmentsAfterImport() {
		let found = PageSizeRule.pageAssignments(in: "@charset \"utf-8\";\n@import url(x.css);\n.wide { page: wide }")
		#expect(found.map(\.selector) == [".wide"])
	}

	@Test("side margins: recto and verso differ by the inside/outside margin")
	func sideMargins() throws {
		let css = "@page :right { margin-left: 22mm; margin-right: 17mm } @page :left { margin-left: 17mm; margin-right: 22mm }"
		let margins = try #require(PageSizeRule.sideMargins(in: css))
		let mm = 72 / 25.4
		#expect(abs(margins.margins(pageIndex: 0).left - 22 * mm) < 0.01)
		#expect(abs(margins.margins(pageIndex: 1).left - 17 * mm) < 0.01)
		#expect(abs(margins.shift(pageIndex: 1) + 5 * mm) < 0.01)
		#expect(margins.shift(pageIndex: 2) == 0)
		#expect(PageSizeRule.sideMargins(in: "@page { margin: 10mm }") == nil)
	}
}
