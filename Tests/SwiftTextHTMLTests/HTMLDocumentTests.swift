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

// The convenience initializer is available wherever WebKit is, so these are not
// macOS-only the way the `WebKitBrowser` tests below are — they compile and run
// on iOS, which is what proves the port. Their `@available(iOS 16.0, *)` is the
// price of the `.timeLimit` hang guard: the trait takes a `Duration`, which is
// iOS 16, one version above the package floor. Better a guard that sits out iOS
// 15 than a suite that can hang on every platform.
#if os(macOS) || os(iOS)
/// A page whose body only exists after its scripts have run. Parsing the raw
/// source yields `LOADING`; parsing the settled DOM yields the heading. Using a
/// fixture where the two differ is the point — a real page whose text is already
/// in the server HTML passes whether or not JavaScript ever executed.
private func writeHydratingFixture() throws -> URL {
	let html = """
	<html><body><div id="root">LOADING</div>
	<script>
		document.addEventListener('DOMContentLoaded', function () {
			document.getElementById('root').innerHTML = '<h1>Hydrated</h1><p>Written by <b>JavaScript</b>.</p>';
		});
	</script>
	</body></html>
	"""
	let fileURL = FileManager.default.temporaryDirectory
		.appendingPathComponent("swifttext-hydration-\(UUID().uuidString).html")
	try html.write(to: fileURL, atomically: true, encoding: .utf8)
	return fileURL
}

/// The headline of #52: one call from a URL to Markdown, with the page's own
/// scripts having run first.
@available(iOS 16.0, *)
@Test(.timeLimit(.minutes(1)))
func htmlDocumentExecutesJavaScript() async throws {
	let fileURL = try writeHydratingFixture()
	defer { try? FileManager.default.removeItem(at: fileURL) }

	let markdown = try await HTMLDocument(url: fileURL, executingJavaScript: true).markdown()
	#expect(markdown.contains("# Hydrated"))
	#expect(markdown.contains("Written by **JavaScript**."))
	#expect(!markdown.contains("LOADING"), "the pre-hydration DOM was captured")
}

/// `executingJavaScript: false` must skip WebKit entirely and fetch directly —
/// the cheap path for server-rendered pages. Same fixture, opposite result.
@available(iOS 16.0, *)
@Test(.timeLimit(.minutes(1)))
func htmlDocumentWithoutJavaScriptFetchesDirectly() async throws {
	let fileURL = try writeHydratingFixture()
	defer { try? FileManager.default.removeItem(at: fileURL) }

	let markdown = try await HTMLDocument(url: fileURL, executingJavaScript: false).markdown()
	#expect(markdown.contains("LOADING"))
	#expect(!markdown.contains("Hydrated"), "scripts ran on the no-JavaScript path")
}

/// A load failure has to reach the caller as an error rather than an empty
/// document — the initializer is the only thing an app-side caller sees.
@available(iOS 16.0, *)
@Test(.timeLimit(.minutes(1)))
func htmlDocumentReportsJavaScriptLoadFailure() async throws {
	let missing = FileManager.default.temporaryDirectory
		.appendingPathComponent("swifttext-missing-\(UUID().uuidString).html")
	await #expect(throws: WebKitBrowserError.self) {
		_ = try await HTMLDocument(url: missing, executingJavaScript: true)
	}
}
#endif

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

/// The Swift-side backstop fires even when WebKit never calls back at all.
///
/// The page busy-waits, which blocks the web content process's main thread, so
/// the navigation cannot finish and the capture script is never injected — the
/// watchdog is the only thing that can end this load. Racing a short timeout
/// against the injected script's 500 ms debounce instead would be flaky: under a
/// loaded machine `Task.sleep` overshoots, and the script's message can land
/// first. The block is bounded so the process doesn't spin past the test.
@Test(.timeLimit(.minutes(1)))
@MainActor
func webKitBrowserTimesOut() async throws {
	let stalling = """
	<html><body><p>Hello</p>
	<script>var end = Date.now() + 3000; while (Date.now() < end) {}</script>
	</body></html>
	"""
	let browser = WebKitBrowser(htmlString: stalling)
	browser.timeout = 0.3
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
