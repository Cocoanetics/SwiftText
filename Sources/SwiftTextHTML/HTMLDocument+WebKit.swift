//  HTMLDocument+WebKit.swift
//  SwiftTextHTML
//
//  Loading a page through WebKit so its scripts run, then parsing the resulting
//  DOM. Available wherever WebKit is (macOS, iOS, Mac Catalyst).
//
//  This is the public face of `WebKitBrowser`, which stays package-internal.
//  Driving a WKWebView is a few dozen lines any app developer can write; what is
//  worth sharing is knowing *when the page is done*. Hooking `didFinish` — the
//  obvious approach — fires before a single-page app has hydrated, so you
//  capture a spinner and an empty `<div id="root">`. The browser instead watches
//  for DOM mutations to stop arriving, which is why this exists as API.
//
//  Nothing is going to replace WebKit's JavaScript execution in portable Swift.
//  The rendering side has a pure-Swift answer (SwiftTextRender); running a
//  page's own scripts does not — so this is the one place where depending on a
//  platform framework is permanent rather than transitional.

#if os(macOS) || os(iOS)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@available(macOS 10.15, iOS 13.0, *)
extension HTMLDocument {

	/// Loads `url` and parses the result.
	///
	/// - Parameters:
	///   - url: The page to load.
	///   - executingJavaScript: When `true`, the page is loaded in a WKWebView
	///     and captured once its DOM stops changing, so client-rendered content
	///     is included. When `false`, the HTML is fetched directly — much
	///     cheaper, and correct for server-rendered pages.
	///   - timeout: How long to wait for the page to settle before giving up.
	///     Ignored unless `executingJavaScript` is `true`. Pass `0` to wait
	///     indefinitely — inadvisable in an app, where the web content process
	///     can be suspended or killed while you wait.
	/// - Throws: ``WebKitBrowserError`` if the page failed to load, timed out, or
	///   yielded no HTML; a `URLError` if a direct fetch failed; or
	///   ``HTMLDocumentError`` if the result could not be parsed.
	public convenience init(
		url: URL,
		executingJavaScript: Bool,
		timeout: TimeInterval = 10
	) async throws {
		if executingJavaScript {
			let html = try await javaScriptRenderedHTML(from: url, timeout: timeout)
			try await self.init(data: Data(html.utf8), baseURL: url)
		} else {
			let (data, _) = try await URLSession.shared.data(from: url)
			try await self.init(data: data, baseURL: url)
		}
	}
}

/// Runs the page and returns the settled DOM.
///
/// `WebKitBrowser` is `@MainActor` throughout — WKWebView requires it — so this
/// hop is where the caller's nonisolated context meets it.
@available(macOS 10.15, iOS 13.0, *)
@MainActor
private func javaScriptRenderedHTML(from url: URL, timeout: TimeInterval) async throws -> String {
	let browser = WebKitBrowser(url: url)
	browser.timeout = timeout
	await browser.waitForLoadCompletion()

	if let loadError = browser.loadError {
		throw loadError
	}
	guard let html = await browser.html() else {
		throw WebKitBrowserError.missingHTML
	}
	return html
}
#endif
