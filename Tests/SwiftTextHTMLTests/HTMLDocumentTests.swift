import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftTextCore
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

@Test
func extractedHTMLTextCanBeSanitizedExplicitly() async throws {
	let html = """
	<html>
	<body>
		<p>Hello\u{202E} there\u{202C}</p>
	</body>
	</html>
	"""
	let document = try await HTMLDocument(data: Data(html.utf8))

	let rawText = document.text()
	let sanitization = UnicodeAbuseSanitizer.sanitize(rawText)

	#expect(rawText.contains("\u{202E}"))
	#expect(sanitization.text == "Hello there")
	#expect(sanitization.report.hasBidiOverrides)
}

@Test
func skippedInlineTagDoesNotSplitParagraph() async throws {
	// A non-rendering tag inside inline content must be dropped without splitting
	// the paragraph around it.
	let html = "<html><body><p>Hello<script>var x = 1;</script>world</p></body></html>"
	let document = try await HTMLDocument(data: Data(html.utf8))
	#expect(document.markdown() == "Helloworld")
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

/// A failed navigation must surface as an error, not hang. Before the
/// `didFailProvisionalNavigation` handler existed, the injected script never
/// ran, so nothing ever resumed the waiter and this call blocked forever — the
/// time limit is what turns a regression into a failure instead of a hung suite.
@Test(.timeLimit(.minutes(1)))
@MainActor
func webKitBrowserReportsNavigationFailure() async throws {
	// A file that isn't there: fails locally, with no network or DNS in play.
	// (A refused TCP port is not equivalent — WebKit blocks low ports outright
	// and reports `didFinish` on an empty document instead of failing.)
	let missing = FileManager.default.temporaryDirectory
		.appendingPathComponent("swifttext-missing-\(UUID().uuidString).html")
	let browser = WebKitBrowser(fileURL: missing, readAccessRoot: FileManager.default.temporaryDirectory)
	await browser.waitForLoadCompletion()

	#expect(await browser.html() == nil)
	let error = try #require(browser.loadError as? WebKitBrowserError)
	guard case .loadFailed = error else {
		Issue.record("expected .loadFailed, got \(error)")
		return
	}

	// Every export reports the real cause, not a vague "no HTML". `exportHTML`
	// used to swallow it and throw `.missingHTML` instead.
	let destination = FileManager.default.temporaryDirectory
		.appendingPathComponent("swifttext-export-\(UUID().uuidString).html")
	defer { try? FileManager.default.removeItem(at: destination) }
	await #expect(throws: WebKitBrowserError.self) {
		try await browser.exportHTML(to: destination)
	}
	#expect(!FileManager.default.fileExists(atPath: destination.path))
}

/// The Swift-side backstop fires even when the page itself is fine — proving it
/// doesn't depend on WebKit calling back at all. The injected script debounces
/// for 500 ms before posting, so a 50 ms budget always expires first.
@Test(.timeLimit(.minutes(1)))
@MainActor
func webKitBrowserTimesOut() async throws {
	let browser = WebKitBrowser(htmlString: "<html><body><p>Hello</p></body></html>")
	browser.timeout = 0.05
	await browser.waitForLoadCompletion()

	let error = try #require(browser.loadError as? WebKitBrowserError)
	guard case .timedOut = error else {
		Issue.record("expected .timedOut, got \(error)")
		return
	}
	// The export methods rethrow it rather than emitting a blank page.
	await #expect(throws: WebKitBrowserError.self) {
		_ = try await browser.exportPDFData()
	}
}

/// Registering the browser itself as the script-message handler used to close a
/// cycle — browser → web view → configuration → content controller → browser —
/// so every load leaked an instance and its web content process.
@Test(.timeLimit(.minutes(1)))
@MainActor
func webKitBrowserDeallocatesAfterLoad() async throws {
	weak var weakBrowser: WebKitBrowser?

	do {
		let browser = WebKitBrowser(htmlString: "<html><body><p>Hello</p></body></html>")
		await browser.waitForLoadCompletion()
		#expect(await browser.html() != nil)
		weakBrowser = browser
	}

	#expect(weakBrowser == nil, "WebKitBrowser leaked — the script-message handler cycle is back")
}
#endif
