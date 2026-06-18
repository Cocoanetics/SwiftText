import Foundation
import Testing

@testable import SwiftTextPages

@Suite("Legacy iWork '09 parsing")
struct PagesLegacyTests {
	/// A minimal APXL `index.xml` exercising headings (via style names), style
	/// inheritance, header exclusion, `<sf:br>`, and `<sf:ghost-text>` skipping.
	private static let sampleXML = """
	<?xml version="1.0"?>
	<sl:document xmlns:sf="http://developer.apple.com/namespaces/sf" \
	xmlns:sfa="http://developer.apple.com/namespaces/sfa" \
	xmlns:sl="http://developer.apple.com/namespaces/sl">
	<sf:stylesheet>
	<sf:paragraphstyle sf:name="Title" sf:ident="ps-title" sfa:ID="PS-TITLE"/>
	<sf:paragraphstyle sf:name="Heading 2" sf:ident="ps-h2" sfa:ID="PS-H2"/>
	<sf:paragraphstyle sf:name="Body" sf:ident="ps-body" sfa:ID="PS-BODY"/>
	<sf:paragraphstyle sf:ident="ps-body-child" sfa:ID="PS-BODY-CHILD" sf:parent-ident="ps-body"/>
	</sf:stylesheet>
	<sf:header><sf:text-storage sf:kind="header"><sf:text-body>
	<sf:p sf:style="PS-BODY"><sf:span>This header must be ignored.</sf:span></sf:p>
	</sf:text-body></sf:text-storage></sf:header>
	<sf:text-storage sf:kind="body"><sf:text-body>
	<sf:p sf:style="PS-TITLE"><sf:span>The Grand Title</sf:span></sf:p>
	<sf:p sf:style="PS-H2"><sf:span>First Section</sf:span></sf:p>
	<sf:p sf:style="PS-BODY-CHILD"><sf:span>Body via inherited style.</sf:span></sf:p>
	<sf:p sf:style="PS-BODY"><sf:span>Line one</sf:span><sf:br/><sf:span>line two</sf:span></sf:p>
	<sf:p sf:style="PS-BODY"><sf:ghost-text>placeholder skip me</sf:ghost-text><sf:span>Real text.</sf:span></sf:p>
	</sf:text-body></sf:text-storage>
	</sl:document>
	"""

	private func makeLegacyBundle() throws -> URL {
		let bundle = FileManager.default.temporaryDirectory
			.appendingPathComponent("legacy-\(UUID().uuidString).pages", isDirectory: true)
		try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
		try Data(PagesLegacyTests.sampleXML.utf8)
			.write(to: bundle.appendingPathComponent("index.xml"))
		return bundle
	}

	@Test("Extracts body paragraphs and skips headers and ghost text")
	func extractsBodyText() throws {
		let bundle = try makeLegacyBundle()
		defer { try? FileManager.default.removeItem(at: bundle) }

		let pages = try PagesFile(url: bundle)
		#expect(pages.plainTextParagraphs() == [
			"The Grand Title",
			"First Section",
			"Body via inherited style.",
			"Line one\nline two",
			"Real text."
		])
	}

	@Test("Infers heading levels from style names, including inherited styles")
	func infersHeadingsFromStyleNames() throws {
		let bundle = try makeLegacyBundle()
		defer { try? FileManager.default.removeItem(at: bundle) }

		let markdown = try PagesFile(url: bundle).markdown()
		#expect(markdown.hasPrefix("# The Grand Title"))
		#expect(markdown.contains("## First Section"))
		// A body style (even when reached through inheritance) is not a heading.
		#expect(markdown.contains("\n\nBody via inherited style.\n\n"))
		#expect(!markdown.contains("# Body"))
	}

	@Test("Maps standard style names to heading levels across languages")
	func headingLevelNameMapping() {
		#expect(PagesLegacyHeading.level(forStyleName: "Title") == 1)
		#expect(PagesLegacyHeading.level(forStyleName: "Heading 1") == 1)
		#expect(PagesLegacyHeading.level(forStyleName: "Heading 3") == 3)
		#expect(PagesLegacyHeading.level(forStyleName: "Überschrift 2") == 2)
		#expect(PagesLegacyHeading.level(forStyleName: "Subtitle") == 2)
		#expect(PagesLegacyHeading.level(forStyleName: "Body") == nil)
		#expect(PagesLegacyHeading.level(forStyleName: "Normal") == nil)
		#expect(PagesLegacyHeading.level(forStyleName: nil) == nil)
	}
}
