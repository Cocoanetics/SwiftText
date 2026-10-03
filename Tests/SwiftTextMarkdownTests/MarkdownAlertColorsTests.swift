import Testing

@testable import SwiftTextMarkdown

@Suite("Alert colours read from a stylesheet")
struct MarkdownAlertColorsTests {
	@Test("Without alert rules, every kind keeps its built-in colours")
	func builtInWithoutRules() {
		let colors = MarkdownAlertColors(css: "body { color: #123456; } .markdown-alert p { color: #000; }")
		#expect(colors.isEmpty)
		#expect(colors.palette(forKind: "note") == .note)
		#expect(colors.palette(forKind: "careful") == .neutral)
	}

	@Test("A kind's rule recolours that kind only")
	func kindRule() {
		let colors = MarkdownAlertColors(css: """
		/* the book's boxes */
		.markdown-alert-careful { background: #f6f1ea; border-left-color: #b8975a; color: #3b3222; }
		""")
		#expect(colors.palette(forKind: "careful") == MarkdownAlertPalette(background: "F6F1EA", border: "B8975A", text: "3B3222"))
		#expect(colors.palette(forKind: "note") == .note)
	}

	@Test("Rules win as in CSS: by specificity, then by order")
	func cascade() {
		let colors = MarkdownAlertColors(css: """
		.markdown-alert-note { background: #111111; }
		.markdown-alert { background: #222222; border-left: 4px solid #333333; }
		.markdown-alert-tip { background: #444444; }
		aside.markdown-alert-warning { background: #555555; }
		.markdown-alert { color: #666666; }
		""")
		#expect(colors.palette(forKind: "note").background == "222222")      // the later base rule wins
		#expect(colors.palette(forKind: "tip").background == "444444")       // the later kind rule wins
		#expect(colors.palette(forKind: "warning").background == "555555")   // more specific than the base rule
		#expect(colors.palette(forKind: "example").border == "333333")
		#expect(colors.palette(forKind: "caution").text == "666666")
	}

	@Test("!important wins over specificity and order, as in CSS")
	func important() {
		let colors = MarkdownAlertColors(css: """
		.markdown-alert-note { background: #f00 !important; }
		aside.markdown-alert-note { background: #00f; }
		.markdown-alert { color: #111111 ! IMPORTANT; }
		.markdown-alert-tip { color: #222222; }
		""")
		#expect(colors.palette(forKind: "note").background == "FF0000")
		#expect(colors.palette(forKind: "tip").text == "111111")
	}

	@Test("Only selectors the generated <aside> can match: no other tag, no other class")
	func selectorsMustMatchTheBox() {
		let colors = MarkdownAlertColors(css: """
		.markdown-alert { background: #ffffff; }
		section.markdown-alert-note { background: #ff0000; }
		.special.markdown-alert-note { background: #00ff00; }
		.markdown-alert-NOTE { background: #0000ff; }
		.markdown-alert-note.markdown-alert-tip { background: #123456; }
		ASIDE.markdown-alert.markdown-alert-warning { background: #abcdef; }
		""")
		#expect(colors.palette(forKind: "note").background == "FFFFFF")
		#expect(colors.palette(forKind: "tip").background == "FFFFFF")
		#expect(colors.palette(forKind: "warning").background == "ABCDEF")
	}

	@Test("Hex, rgb() and rgba() colours; translucent ones are mixed with white")
	func colorFormats() {
		#expect(MarkdownAlertColors.hexColor(in: "#abc") == "AABBCC")
		#expect(MarkdownAlertColors.hexColor(in: "rgb(184, 151, 90)") == "B8975A")
		#expect(MarkdownAlertColors.hexColor(in: "rgba(184, 151, 90, 0.13)") == "F6F1EA")
		#expect(MarkdownAlertColors.hexColor(in: "rgb(184 151 90 / 13%)") == "F6F1EA")
		#expect(MarkdownAlertColors.hexColor(in: "#b8975aff") == "B8975A")
		#expect(MarkdownAlertColors.hexColor(in: "1px solid #9A6700 !important") == "9A6700")
		#expect(MarkdownAlertColors.hexColor(in: "transparent") == nil)
	}

	@Test("The title's rules, descendant selectors and at-rules don't colour boxes")
	func ignoredRules() {
		let colors = MarkdownAlertColors(css: """
		.markdown-alert-title { color: #ff0000; }
		.markdown-alert > p { color: #00ff00; }
		@media print { .markdown-alert-note { background: #0000ff; } }
		@import url("x.css");
		.markdown-alert-note:hover { background: #ff00ff; }
		""")
		#expect(colors.isEmpty)
		#expect(colors.palette(forKind: "note") == .note)
	}
}
