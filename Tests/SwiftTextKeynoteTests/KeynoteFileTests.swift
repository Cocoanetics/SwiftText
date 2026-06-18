import Foundation
import Testing

import SwiftTextKeynote

/// Exercises the Keynote reader against `Sample.key`, a clean two-slide deck authored
/// in Keynote (titles + bulleted bodies). It pins deck-slide navigation (content slides
/// separated from the theme's 17 layout (master) slides) and the placeholder text path.
@Suite("Keynote reader")
struct KeynoteFileTests {
	private func fixture() throws -> KeynoteFile {
		let url = try #require(Bundle.module.url(forResource: "Sample", withExtension: "key"))
		return try KeynoteFile(url: url)
	}

	@Test("Reads the deck's slides, not the theme's layout slides")
	func readsDeckSlidesNotLayouts() throws {
		let document = try fixture().document
		// The deck has exactly two slides; the theme's 17 layout (master) slides are excluded.
		#expect(document.slides.count == 2)
	}

	@Test("Extracts each slide's title and body")
	func extractsTitleAndBody() throws {
		let slides = try fixture().document.slides
		#expect(slides[0].title == "Quarterly Review")
		#expect(slides[0].body.joined().contains("Revenue up 12%"))
		#expect(slides[0].body.joined().contains("Hiring two engineers"))
		#expect(slides[1].title == "Next Steps")
		#expect(slides[1].body.joined().contains("Ship Numbers reader"))
	}

	@Test("Markdown renders headings and bullets")
	func markdownRendersHeadingsAndBullets() throws {
		let markdown = try fixture().markdown()
		#expect(markdown.contains("## Quarterly Review"))
		#expect(markdown.contains("- Revenue up 12%"))
		#expect(markdown.contains("- Costs flat"))
		#expect(markdown.contains("## Next Steps"))
	}

	@Test("JSON round-trips through the Codable model")
	func jsonRoundTripsThroughCodableModel() throws {
		let jsonString = try fixture().json()
		let decoded = try JSONDecoder().decode(KeynoteDocument.self, from: Data(jsonString.utf8))
		#expect(decoded.slides.count == 2)
		#expect(decoded.slides.first?.title == "Quarterly Review")
	}
}
