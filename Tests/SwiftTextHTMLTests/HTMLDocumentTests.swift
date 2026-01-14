import Foundation
import SwiftTextHTML
import Testing

@Test
func htmlDocumentParsesRemoteURL() async throws {
	let url = try #require(URL(string: "https://www.cocoanetics.com/2025/12/swifttext/"))
	let (data, _) = try await URLSession.shared.data(from: url)
	let document = try await HTMLDocument(data: data, baseURL: url)
	let text = document.text()
	#expect(!text.isEmpty)
	#expect(text.localizedCaseInsensitiveContains("SwiftText"))
}

@Test
func markdownResolvesRelativeImageURLsAgainstBaseURL() async throws {
	let html = """
	<html>
	<body>
		<img src="/mattt/iMCP/raw/main/Assets/calendar.svg" alt="Calendar" />
	</body>
	</html>
	"""
	let baseURL = try #require(URL(string: "https://github.com/mattt/iMCP"))
	let document = try await HTMLDocument(data: Data(html.utf8), baseURL: baseURL)
	let markdown = document.markdown()
	#expect(markdown.contains("![Calendar](https://github.com/mattt/iMCP/raw/main/Assets/calendar.svg)"))
}

#if os(macOS)
@Test
@MainActor
func webKitBrowserLoadsHTML() async throws {
	let url = try #require(URL(string: "https://www.cocoanetics.com/2025/12/swifttext/"))
	let browser = WebKitBrowser(url: url)
	await browser.waitForLoadCompletion()
	let html = await browser.html()
	#expect(html?.localizedCaseInsensitiveContains("SwiftText") == true)
}
#endif
