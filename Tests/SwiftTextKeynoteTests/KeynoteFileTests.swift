import XCTest
import SwiftTextKeynote

/// Exercises the Keynote reader against `Sample.key`, a clean two-slide deck authored
/// in Keynote (titles + bulleted bodies). It pins deck-slide navigation (content slides
/// separated from the theme's 17 layout (master) slides) and the placeholder text path.
final class KeynoteFileTests: XCTestCase {
	private func fixture() throws -> KeynoteFile {
		let url = try XCTUnwrap(Bundle.module.url(forResource: "Sample", withExtension: "key"))
		return try KeynoteFile(url: url)
	}

	func testReadsDeckSlidesNotLayouts() throws {
		let document = try fixture().document
		// The deck has exactly two slides; the theme's 17 layout (master) slides are excluded.
		XCTAssertEqual(document.slides.count, 2)
	}

	func testExtractsTitleAndBody() throws {
		let slides = try fixture().document.slides
		XCTAssertEqual(slides[0].title, "Quarterly Review")
		XCTAssertTrue(slides[0].body.joined().contains("Revenue up 12%"))
		XCTAssertTrue(slides[0].body.joined().contains("Hiring two engineers"))
		XCTAssertEqual(slides[1].title, "Next Steps")
		XCTAssertTrue(slides[1].body.joined().contains("Ship Numbers reader"))
	}

	func testMarkdownRendersHeadingsAndBullets() throws {
		let markdown = try fixture().markdown()
		XCTAssertTrue(markdown.contains("## Quarterly Review"))
		XCTAssertTrue(markdown.contains("- Revenue up 12%"))
		XCTAssertTrue(markdown.contains("- Costs flat"))
		XCTAssertTrue(markdown.contains("## Next Steps"))
	}

	func testJSONRoundTripsThroughCodableModel() throws {
		let jsonString = try fixture().json()
		let decoded = try JSONDecoder().decode(KeynoteDocument.self, from: Data(jsonString.utf8))
		XCTAssertEqual(decoded.slides.count, 2)
		XCTAssertEqual(decoded.slides.first?.title, "Quarterly Review")
	}
}
