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

extension WebKitIntegrationTests {
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
