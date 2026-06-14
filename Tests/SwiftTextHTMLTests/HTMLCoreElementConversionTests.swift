import Foundation
import SwiftTextHTML
import Testing

/// Per-element HTML→Markdown conversion, exercising `DOMMarkupConverter`'s inline
/// and leaf-block handling — much of it capability the previous string renderer
/// lacked (strikethrough, thematic breaks, hard breaks, linked images).
@Suite("HTML core element conversion")
struct HTMLCoreElementConversionTests {

	private func markdown(_ html: String) async throws -> String {
		try await HTMLDocument(data: Data(html.utf8)).markdown()
	}

	@Test func headingsAllLevels() async throws {
		let html = "<h1>A</h1><h2>B</h2><h3>C</h3><h4>D</h4><h5>E</h5><h6>F</h6>"
		let expected = [
			"# A", "", "## B", "", "### C", "", "#### D", "", "##### E", "", "###### F",
		].joined(separator: "\n")
		#expect(try await markdown(html) == expected)
	}

	@Test func strongAndBoldAlias() async throws {
		#expect(try await markdown("<p><strong>s</strong> and <b>b</b></p>") == "**s** and **b**")
	}

	@Test func emphasisAndItalicAlias() async throws {
		#expect(try await markdown("<p><em>e</em> and <i>i</i></p>") == "*e* and *i*")
	}

	/// CommonMark rejects `** bold **`, so whitespace inside the markers must be
	/// pushed outside them.
	@Test func emphasisWhitespaceIsExternalized() async throws {
		#expect(try await markdown("<p>x<strong> bold </strong>y</p>") == "x **bold** y")
		#expect(try await markdown("<p>This is <em>very </em>important.</p>") == "This is *very* important.")
	}

	@Test func strikethroughVariants() async throws {
		#expect(try await markdown("<p><del>d</del> <s>s</s> <strike>k</strike></p>") == "~d~ ~s~ ~k~")
	}

	@Test func nestedEmphasis() async throws {
		#expect(try await markdown("<p><strong><em>both</em></strong></p>") == "***both***")
	}

	@Test func inlineCode() async throws {
		#expect(try await markdown("<p>Use <code>x = 1</code> here.</p>") == "Use `x = 1` here.")
	}

	@Test func fencedCodeBlockFromPreCode() async throws {
		#expect(try await markdown("<pre><code>let a = 1\nlet b = 2</code></pre>") == "```\nlet a = 1\nlet b = 2\n```")
	}

	@Test func codeBlockPreservesInnerWhitespace() async throws {
		#expect(try await markdown("<pre>raw\n  indented</pre>") == "```\nraw\n  indented\n```")
	}

	@Test func thematicBreak() async throws {
		let expected = ["before", "", "-----", "", "after"].joined(separator: "\n")
		#expect(try await markdown("<p>before</p><hr><p>after</p>") == expected)
	}

	@Test func lineBreakBecomesHardBreak() async throws {
		// `<br>` is a real hard break: two trailing spaces before the newline.
		#expect(try await markdown("<p>line one<br>line two</p>") == "line one  \nline two")
	}

	@Test func externalLink() async throws {
		let html = "<p>see <a href=\"https://example.com/p\">the page</a> now</p>"
		#expect(try await markdown(html) == "see [the page](https://example.com/p) now")
	}

	@Test func dataURIImageIsDropped() async throws {
		#expect(try await markdown("<p><img src=\"data:image/png;base64,AAAA\" alt=\"x\"></p>").isEmpty)
	}

	@Test func imageWithoutAltUsesFallback() async throws {
		#expect(try await markdown("<p><img src=\"pic.png\"></p>") == "![Image](pic.png)")
	}

	@Test func linkedImage() async throws {
		let html = "<p><a href=\"https://e.com\"><img src=\"logo.png\" alt=\"Logo\"></a></p>"
		#expect(try await markdown(html) == "[![Logo](logo.png)](https://e.com)")
	}
}
