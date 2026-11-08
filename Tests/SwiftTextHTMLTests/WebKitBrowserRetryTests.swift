//  WebKitBrowserRetryTests.swift
//  SwiftTextHTMLTests
//
//  A navigation that never commits — the web content process never launched or
//  never answered — must not just sit out the whole timeout. The commit watchdog
//  replaces the web view and retries; if that stalls too, the timeout names the
//  phase it stalled in.

#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import SwiftTextHTML

/// Serves `swifttext-stall:` URLs, never answering the first `stalledRequests`
/// requests. An unanswered request leaves its navigation provisional forever —
/// exactly the never-committing navigation the watchdog is for.
@MainActor
private final class StallingSchemeHandler: NSObject, WKURLSchemeHandler {
	static let scheme = "swifttext-stall"

	let stalledRequests: Int
	private(set) var requests = 0

	init(stalledRequests: Int) {
		self.stalledRequests = stalledRequests
	}

	func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
		requests += 1
		guard requests > stalledRequests, let url = urlSchemeTask.request.url else { return }
		let html = Data("<html><body><p>Recovered</p></body></html>".utf8)
		urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: html.count, textEncodingName: "utf-8"))
		urlSchemeTask.didReceive(html)
		urlSchemeTask.didFinish()
	}

	func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// Serves a first page that navigates on a second after it loads, and answers
/// that second page only after 5 s. Neither page lets its own timers capture it:
/// `setTimeout` is disabled, so only the Swift-side fallback can.
@MainActor
private final class HoppingSchemeHandler: NSObject, WKURLSchemeHandler {
	static let scheme = "swifttext-hop"

	private var stopped: Set<ObjectIdentifier> = []

	func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
		guard let url = urlSchemeTask.request.url else { return }
		if url.path == "/second" {
			let id = ObjectIdentifier(urlSchemeTask as AnyObject)
			Task { @MainActor in
				try? await Task.sleep(nanoseconds: 5_000_000_000)
				guard !self.stopped.contains(id) else { return }
				Self.respond(urlSchemeTask, url: url, html: """
				<html><head><script>window.setTimeout = function() { return 0; };</script></head>
				<body><p>Second page</p></body></html>
				""")
			}
		} else {
			Self.respond(urlSchemeTask, url: url, html: """
			<html><head><script>
			var later = window.setTimeout.bind(window);
			window.setTimeout = function() { return 0; };
			window.addEventListener('load', function() {
				later(function() { location.href = '\(Self.scheme)://site/second'; }, 1000);
			});
			</script></head><body><p>First page</p></body></html>
			""")
		}
	}

	func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
		stopped.insert(ObjectIdentifier(urlSchemeTask as AnyObject))
	}

	private static func respond(_ task: any WKURLSchemeTask, url: URL, html: String) {
		let data = Data(html.utf8)
		task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
		task.didReceive(data)
		task.didFinish()
	}
}

extension WebKitIntegrationTests {
	/// The first page's fallback is due 3 s after it finished, while the second
	/// page is still on its way. Starting that navigation must cancel it, or the
	/// first page — no longer the one being loaded — is captured instead.
	@Test("A page that navigates on is captured at its destination", .timeLimit(.minutes(1)))
	@MainActor
	func webKitBrowserCapturesAfterClientNavigation() async throws {
		let handler = HoppingSchemeHandler()
		let browser = WebKitBrowser(url: try #require(URL(string: "\(HoppingSchemeHandler.scheme)://site/first")))
		browser.configureWebView = { configuration in
			configuration.setURLSchemeHandler(handler, forURLScheme: HoppingSchemeHandler.scheme)
		}
		browser.timeout = 20
		await browser.waitForLoadCompletion()

		#expect(browser.loadError == nil, "\(String(describing: browser.loadError))")
		let html = await browser.html()
		#expect(html?.contains("Second page") == true, "captured: \(html ?? "nil")")
	}

	@MainActor
	private func stallingBrowser(handler: StallingSchemeHandler) throws -> WebKitBrowser {
		let browser = WebKitBrowser(url: try #require(URL(string: "\(StallingSchemeHandler.scheme)://page")))
		browser.configureWebView = { configuration in
			configuration.setURLSchemeHandler(handler, forURLScheme: StallingSchemeHandler.scheme)
		}
		return browser
	}

	/// Without the watchdog the first web view waits out the full 20 s timeout and
	/// the load fails; with it, the retry on a fresh web view captures the page.
	@Test("A navigation that never commits is retried on a fresh web view", .timeLimit(.minutes(1)))
	@MainActor
	func webKitBrowserRetriesUncommittedNavigation() async throws {
		let handler = StallingSchemeHandler(stalledRequests: 1)
		let browser = try stallingBrowser(handler: handler)
		browser.timeout = 20
		browser.commitTimeout = 1
		await browser.waitForLoadCompletion()

		#expect(browser.loadError == nil, "\(String(describing: browser.loadError))")
		#expect(await browser.html()?.contains("Recovered") == true)
		#expect(handler.requests == 2)
		#expect(browser.loadProgress.attempt == 2)
	}

	/// The failure #171 actually caught: the page loaded and the capture script ran,
	/// but WebKit throttled the script's timers in the off-screen web view and the
	/// capture never posted. Here the page disables `setTimeout` outright, so only
	/// the Swift-side fallback can capture it.
	@Test("A page whose timers never fire is still captured", .timeLimit(.minutes(1)))
	@MainActor
	func webKitBrowserCapturesWithoutPageTimers() async throws {
		let browser = WebKitBrowser(htmlString: """
		<html><head><script>window.setTimeout = function() { return 0; };</script></head>
		<body><p>Timerless</p></body></html>
		""")
		browser.timeout = 15
		await browser.waitForLoadCompletion()

		#expect(browser.loadError == nil, "\(String(describing: browser.loadError))")
		#expect(await browser.html()?.contains("Timerless") == true)
		#expect(browser.loadProgress.captureScriptRan)
	}

	/// When every attempt stalls, the timeout reports where: after both attempts,
	/// the navigation was issued but never committed.
	@Test("A load that never commits times out naming the stalled phase", .timeLimit(.minutes(1)))
	@MainActor
	func webKitBrowserReportsUncommittedStall() async throws {
		let handler = StallingSchemeHandler(stalledRequests: .max)
		let browser = try stallingBrowser(handler: handler)
		browser.timeout = 3
		browser.commitTimeout = 0.5
		await browser.waitForLoadCompletion()

		let error = try #require(browser.loadError as? WebKitBrowserError)
		guard case .timedOut(_, let progress) = error else {
			Issue.record("expected .timedOut, got \(error)")
			return
		}
		#expect(progress.attempt == 2)
		#expect(progress.maxAttempts == 2)
		#expect(progress.navigationIssued)
		#expect(!progress.committed)
		#expect(!progress.captureScriptRan)
		#expect(handler.requests == 2)
		#expect(error.localizedDescription.contains("never: committed"))
	}
}
#endif
