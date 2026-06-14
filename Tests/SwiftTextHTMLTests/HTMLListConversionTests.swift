import Foundation
import SwiftTextHTML
import Testing

/// HTML→Markdown list conversion, now driven by swift-markdown's `MarkupFormatter`.
@Suite("HTML list conversion")
struct HTMLListConversionTests {

	@Test func orderedListUsesIncrementingNumerals() async throws {
		let html = "<html><body><ol><li>one</li><li>two</li><li>three</li></ol></body></html>"
		let document = try await HTMLDocument(data: Data(html.utf8))
		let markdown = document.markdown()

		let expected = [
			"1. one",
			"2. two",
			"3. three",
		].joined(separator: "\n")
		#expect(markdown == expected)
	}

	@Test func unorderedListUsesDashMarkers() async throws {
		let html = "<html><body><ul><li>alpha</li><li>beta</li></ul></body></html>"
		let document = try await HTMLDocument(data: Data(html.utf8))
		let markdown = document.markdown()

		#expect(markdown == "- alpha\n- beta")
	}

	/// A nested list of the *same* type as its parent is correctly indented by
	/// the formatter — a genuine improvement over the previous renderer, which
	/// concatenated the nested list text onto the parent item.
	@Test func sameTypeNestedListIsIndented() async throws {
		let html = """
		<html><body>
		<ul>
			<li>First</li>
			<li>Second:
				<ul><li>inner a</li><li>inner b</li></ul>
			</li>
		</ul>
		</body></html>
		"""
		let document = try await HTMLDocument(data: Data(html.utf8))
		let markdown = document.markdown()

		let expected = [
			"- First",
			"- Second:",
			"  - inner a",
			"  - inner b",
		].joined(separator: "\n")
		#expect(markdown == expected)
	}

	/// Characterizes a known swift-markdown limitation: `MarkupFormatter` only
	/// indents a nested list when it shares its parent list's type, so an `<ol>`
	/// nested in a `<ul>` renders flush-left. The hierarchy still survives in the
	/// AST; only the rendered indentation is lost. Asserted here so the behavior
	/// is explicit and a future upstream fix is noticed.
	///
	/// Upstream fix: https://github.com/swiftlang/swift-markdown/pull/216 (open as
	/// of 0.8.0). When that merges and ships, this expectation should flip to the
	/// indented form.
	@Test func mixedTypeNestedListIsNotIndentedByFormatter() async throws {
		let html = """
		<html><body>
		<ul>
			<li>Item:
				<ol><li>alpha</li><li>beta</li></ol>
			</li>
		</ul>
		</body></html>
		"""
		let document = try await HTMLDocument(data: Data(html.utf8))
		let markdown = document.markdown()

		// Items still land on their own lines (better than the old glued output),
		// but the nested ordered list is not indented under "Item:".
		let expected = [
			"- Item:",
			"1. alpha",
			"2. beta",
		].joined(separator: "\n")
		#expect(markdown == expected)
	}
}
