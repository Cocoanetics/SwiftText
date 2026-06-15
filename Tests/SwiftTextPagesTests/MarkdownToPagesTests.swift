import Foundation
import Testing

@testable import SwiftTextPages

@Suite("Markdown → Pages")
struct MarkdownToPagesTests {
	static let sample = """
	# Document Title

	A paragraph with **bold**, *italic*, ***both***, ~~strike~~, and `inline code`.

	## Section Two

	Some intro text.

	- First bullet
	- Second bullet
	  - Nested bullet

	1. First numbered
	2. Second numbered

	```
	let x = 42
	print(x)
	```

	> A block quote.

	| Name | Count |
	|------|-------|
	| Apples | 3 |
	| Pears | 5 |

	---

	An image ![a diagram](diagram.png) and a [link](https://example.com).
	"""

	@Test("A rich Markdown document writes and reads back through PagesFile")
	func richDocumentRoundTrips() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("swifttext-md-\(UUID().uuidString).pages")
		defer { try? FileManager.default.removeItem(at: url) }

		try MarkdownToPages.convert(Self.sample, to: url)

		let markdown = try PagesFile(url: url).markdown()
		// Headings, inline styling, lists, code, and the image placeholder survive.
		#expect(markdown.contains("Document Title"))
		#expect(markdown.contains("**bold**"))
		#expect(markdown.contains("*italic*"))
		#expect(markdown.contains("~~strike~~"))
		#expect(markdown.contains("First bullet"))
		#expect(markdown.contains("Nested bullet"))
		#expect(markdown.contains("First numbered"))
		#expect(markdown.contains("let x = 42"))
		#expect(markdown.contains("block quote"))
		#expect(markdown.contains("a diagram"))   // image placeholder text
		#expect(markdown.contains("link"))
		#expect(markdown.contains("Name"))        // table header cell
		#expect(markdown.contains("Apples"))      // table body cell
		#expect(markdown.contains("Pears"))
	}
}
