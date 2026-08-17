// WebKit exists on macOS, iOS and Mac Catalyst. The HTML-acquisition path — a
// WKWebView, the settling heuristic, and the captured post-JavaScript DOM — is
// identical API on all of them. Only the paginated PDF export is macOS-only,
// because `NSPrintOperation` has no UIKit twin (tracked separately in #55).
#if os(macOS) || os(iOS)
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import Foundation
import WebKit

@available(macOS 10.15, iOS 13.0, *)
package class WebKitBrowser: NSObject, WKNavigationDelegate {
	// MARK: - Package Properties

	package let url: URL

	// MARK: - Internal Properties
	private static let messageName = "pageLoaded"

	private var webView: WKWebView!
	private var htmlResult: String?
	private var didLoad = false
	/// Whether the load reached a terminal state — captured, failed, or timed out.
	/// Distinct from ``didLoad``, which means the HTML was actually captured.
	private var isFinished = false
	/// Every awaiting `waitForLoadCompletion()` call. A single stored continuation
	/// would be overwritten by a second caller, stranding the first forever.
	private var loadContinuations: [CheckedContinuation<Void, Never>] = []
	private var timeoutTask: Task<Void, Never>?
	private var messageProxy: ScriptMessageProxy?
	private var htmlStringToLoad: String?
	private var fileURLToLoad: URL?
	private var readAccessRoot: URL?

	/// Why the load ended without capturing HTML, or `nil` if it succeeded.
	/// Set before ``waitForLoadCompletion()`` returns, and rethrown by the export
	/// methods.
	package private(set) var loadError: Error?

	/// How long to wait for the page to settle before giving up, in seconds.
	/// Set to `0` to wait indefinitely.
	///
	/// This backstop is what makes the class safe to use in a long-lived app.
	/// The 3 s cap inside the injected script is a JS `setTimeout`, so it only
	/// fires if the page got far enough to *run* that script — it does nothing
	/// for a navigation that fails outright, or for a web content process that
	/// is suspended or killed (which is what happens when an iOS app is
	/// backgrounded) before the script is ever injected.
	package var timeout: TimeInterval = 30

	/// Optional frame size override. When set, the WKWebView is created
	/// with this size so content reflows to the target width (e.g. A4).
	package var frameSize: CGSize?

	/// When `true`, the webview frame is NOT resized to the scroll height
	/// after loading. This lets WebKit paginate content for PDF export.
	package var preserveFrameHeight = false

	// MARK: - Package Interface

	package init(url: URL) {
		self.url = url
		self.htmlStringToLoad = nil
		self.fileURLToLoad = nil
		self.readAccessRoot = nil
		super.init()
	}

	/// Initialise the browser by loading an HTML string directly.
	/// - Parameters:
	///   - htmlString: The HTML content to render.
	///   - baseURL: Optional base URL used to resolve relative resources.
	package init(htmlString: String, baseURL: URL? = nil) {
		self.url = baseURL ?? URL(string: "about:blank")!
		self.htmlStringToLoad = htmlString
		self.fileURLToLoad = nil
		self.readAccessRoot = nil
		super.init()
	}

	/// Initialise the browser by loading a local HTML file with proper file access.
	/// - Parameters:
	///   - fileURL: The file URL to the HTML file.
	///   - readAccessRoot: The directory to grant read access to (for local images/assets).
	package init(fileURL: URL, readAccessRoot: URL) {
		self.url = fileURL
		self.htmlStringToLoad = nil
		self.fileURLToLoad = fileURL
		self.readAccessRoot = readAccessRoot
		super.init()
	}

	/// Waits until the page has settled, failed, or timed out.
	///
	/// Always returns — see ``timeout``. Inspect ``loadError`` to tell a capture
	/// from a failure; the export methods do that for you.
	@MainActor
	package func waitForLoadCompletion() async {
		guard !isFinished else {
			return
		}

		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			loadContinuations.append(continuation)
			// Only the first caller starts the load; later ones just queue up.
			if loadContinuations.count == 1 {
				self.load()
			}
		}
	}

	/// Waits for the load and rethrows whatever ended it badly, so no export
	/// silently operates on a blank page — or reports a vague "no HTML" when the
	/// real cause was a refused connection or a timeout.
	@MainActor
	private func ensureLoaded() async throws {
		await waitForLoadCompletion()
		if let loadError {
			throw loadError
		}
	}

	@MainActor
	private func loadedWebView() async throws -> WKWebView {
		try await ensureLoaded()
		return webView
	}

	@MainActor
	@available(macOS 12.0, iOS 14.0, *)
	package func exportPDF(to outputURL: URL) async throws {
		let webView = try await loadedWebView()
		let data = try await webView.pdf()
		try data.write(to: outputURL)
	}

	/// Exports the rendered page as PDF data.
	///
	/// - Parameter configuration: Optional `WKPDFConfiguration`; defaults to capturing the full page.
	/// - Returns: PDF data for the rendered content.
	@MainActor
	@available(macOS 12.0, iOS 14.0, *)
	package func exportPDFData(configuration: WKPDFConfiguration = WKPDFConfiguration()) async throws -> Data {
		let webView = try await loadedWebView()
		return try await webView.pdf(configuration: configuration)
	}

	#if os(macOS)
	/// Exports the rendered page as paginated PDF data using NSPrintOperation.
	///
	/// Unlike `exportPDFData` (which produces a single continuous page),
	/// this method uses the print pipeline and respects CSS `@page` rules
	/// for page size, margins, and page breaks.
	///
	/// - Parameter paperSize: The paper size in points (e.g. 595.28×841.89 for A4).
	/// - Returns: Paginated PDF data.
	@MainActor
	@available(macOS 11.0, *)
	package func exportPaginatedPDFData(paperSize: CGSize) async throws -> Data {
		let webView = try await loadedWebView()

		let tempURL = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
			.appendingPathExtension("pdf")

		let printInfo = NSPrintInfo()
		printInfo.paperSize = paperSize
		printInfo.topMargin = 0
		printInfo.bottomMargin = 0
		printInfo.leftMargin = 0
		printInfo.rightMargin = 0
		printInfo.horizontalPagination = .fit
		printInfo.verticalPagination = .automatic
		printInfo.isHorizontallyCentered = false
		printInfo.isVerticallyCentered = false
		printInfo.jobDisposition = .save
		printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = tempURL

		let printOperation = webView.printOperation(with: printInfo)
		printOperation.showsPrintPanel = false
		printOperation.showsProgressPanel = false

		let helper = PrintOperationHelper()
		return try await helper.run(printOperation, outputURL: tempURL)
	}
	#endif

	@MainActor
	package func exportHTML(to outputURL: URL) async throws {
		try await ensureLoaded()
		guard let html = htmlResult else {
			throw WebKitBrowserError.missingHTML
		}
		try html.write(to: outputURL, atomically: true, encoding: .utf8)
	}

	// MARK: - Helpers
	@MainActor
	private func load() {
		let config = WKWebViewConfiguration()
		let contentController = WKUserContentController()
		// Register a weak proxy rather than `self`. A user-content controller
		// retains its message handlers, and this object owns the web view that
		// owns the configuration that owns the controller — handing it `self`
		// closes that loop, so the browser (and its web content process) is never
		// released. Harmless in a CLI that exits; an app doing repeated loads
		// leaks a process per instance.
		let proxy = ScriptMessageProxy()
		proxy.target = self
		messageProxy = proxy
		contentController.add(proxy, name: Self.messageName)
		config.userContentController = contentController

		startTimeoutIfNeeded()

		let initialSize = frameSize ?? CGSize(width: 800, height: 600)
		webView = WKWebView(frame: CGRect(origin: .zero, size: initialSize), configuration: config)
		webView.navigationDelegate = self

		if let html = htmlStringToLoad {
			webView.loadHTMLString(html, baseURL: url == URL(string: "about:blank") ? nil : url)
		} else if let fileURL = fileURLToLoad, let readRoot = readAccessRoot {
			webView.loadFileURL(fileURL, allowingReadAccessTo: readRoot)
		} else {
			let urlRequest = URLRequest(url: url)
			webView.load(urlRequest)
		}
	}

	/// Arms the Swift-side backstop that guarantees `waitForLoadCompletion()`
	/// returns even if WebKit never calls back at all.
	@MainActor
	private func startTimeoutIfNeeded() {
		guard timeout > 0 else { return }
		let seconds = timeout
		timeoutTask = Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
			guard let self, !Task.isCancelled else { return }
			self.finish(error: WebKitBrowserError.timedOut(seconds: seconds))
		}
	}

	/// The single exit point for a load. Idempotent: whichever of capture,
	/// navigation failure, process termination, or timeout happens first wins,
	/// and the rest become no-ops.
	@MainActor
	private func finish(error: Error?) {
		guard !isFinished else { return }
		isFinished = true
		// Capturing the page *is* the successful outcome. The frame resize that
		// follows is cosmetic, so a watchdog or a dying web content process
		// during that window must not retroactively fail a load whose HTML we
		// already hold. This keeps the invariant every accessor relies on:
		// `loadError` is non-nil exactly when there is no HTML.
		loadError = didLoad ? nil : error

		timeoutTask?.cancel()
		timeoutTask = nil

		// Drop the message handler as soon as the page is captured: it is the one
		// strong reference WebKit holds on our behalf, and nothing more arrives.
		webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
		messageProxy?.target = nil
		messageProxy = nil

		let waiting = loadContinuations
		loadContinuations.removeAll()
		for continuation in waiting {
			continuation.resume()
		}
	}

	@MainActor
	private func updateWebView(size: CGSize) {
		let width = frameSize?.width ?? 800
		self.webView.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
		#if canImport(UIKit)
		self.webView.layoutIfNeeded()
		#else
		self.webView.layout()
		#endif
	}

	// MARK: - WKNavigationDelegate
	package func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		let js = """
		(function() {
			var observer = new MutationObserver(function(mutations) {
				clearTimeout(window.observerTimeout);
				window.observerTimeout = setTimeout(function() {
					window.webkit.messageHandlers.pageLoaded.postMessage(document.documentElement.outerHTML.toString());
				}, 500);
			});

			observer.observe(document, { childList: true, subtree: true, attributes: true });

			window.addEventListener('load', function() {
				clearTimeout(window.observerTimeout);
				window.observerTimeout = setTimeout(function() {
					window.webkit.messageHandlers.pageLoaded.postMessage(document.documentElement.outerHTML.toString());
				}, 500);
			});

			setTimeout(function() {
				observer.disconnect();
				window.webkit.messageHandlers.pageLoaded.postMessage(document.documentElement.outerHTML.toString());
			}, 3000);
		})();
		"""

		webView.evaluateJavaScript(js) { (_, error) in
			if let error = error {
				print("Error injecting JavaScript: \(error)")
			}
		}
	}

	/// A navigation that started and then failed. Without this the injected
	/// script never runs, so nothing would ever resume the waiters.
	package func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
		finish(error: WebKitBrowserError.loadFailed(underlying: error))
	}

	/// A navigation that never started — bad host, no network, refused
	/// connection. The common failure, and the one that used to hang forever.
	package func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
		finish(error: WebKitBrowserError.loadFailed(underlying: error))
	}

	/// The web content process died — out-of-memory, a crash, or the system
	/// reclaiming it (which is what a backgrounded iOS app's process gets). The
	/// page is gone and no further callback is coming.
	package func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
		finish(error: WebKitBrowserError.webContentProcessTerminated)
	}
}

/// Registered with the user-content controller in place of the browser itself,
/// so WebKit's strong reference to its message handler cannot close a cycle
/// back onto the browser. See the comment in `load()`.
@available(macOS 10.15, iOS 13.0, *)
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
	weak var target: WebKitBrowser?

	func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
		target?.userContentController(userContentController, didReceive: message)
	}
}

@available(macOS 10.15, iOS 13.0, *)
extension WebKitBrowser: WKScriptMessageHandler {
	@objc package func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
		guard message.name == Self.messageName, let html = message.body as? String else {
			return
		}
		guard !isFinished else {
			return
		}

		didLoad = true
		htmlResult = html
		// Disarm the watchdog here rather than in `finish(error:)`: the resize
		// below is an `await`, and the timeout could otherwise fire mid-way and
		// report a timeout for a page that had in fact loaded.
		timeoutTask?.cancel()
		timeoutTask = nil

		Task { @MainActor in
			// A failed resize is not a failed load — we already have the HTML.
			if !self.preserveFrameHeight, let maxSize = try? await self.webView.getMaxScrollSize() {
				self.updateWebView(size: maxSize)
			}
			self.finish(error: nil)
		}
	}
}

@available(macOS 10.15, iOS 13.0, *)
extension WebKitBrowser {
	package func html() async -> String? {
		await waitForLoadCompletion()
		return htmlResult
	}
}

@available(macOS 10.15, iOS 13.0, *)
extension WKWebView {
	func getMaxScrollSize() async throws -> CGSize {
		let jsGetMaxScrollSize = """
		(function() {
			function getMaxScrollSize() {
				var maxWidth = document.documentElement.scrollWidth;
				var maxHeight = document.documentElement.scrollHeight;
				var maxPaddingTop = 0;
				var maxPaddingBottom = 0;
				var elements = document.querySelectorAll('*');
				var maxElement = null;

				for (var i = 0; i < elements.length; i++) {
					var el = elements[i];
					var elScrollHeight = el.scrollHeight;
					var elScrollWidth = el.scrollWidth;

					if (elScrollHeight > document.documentElement.clientHeight || elScrollWidth > document.documentElement.clientWidth) {
						if (elScrollHeight > maxHeight) {
							maxHeight = elScrollHeight;
							maxElement = el;
						}
						maxWidth = Math.max(maxWidth, elScrollWidth);
					}
				}

				if (maxElement) {
					var elementStyles = window.getComputedStyle(maxElement);
					maxPaddingTop = parseFloat(elementStyles.paddingTop) || 0;
					maxPaddingBottom = parseFloat(elementStyles.paddingBottom) || 0;
				}

				maxHeight += maxPaddingTop + maxPaddingBottom;

				return maxWidth + ',' + maxHeight;
			}
			var size = getMaxScrollSize();
			return size;
		})();
		"""

		return try await withCheckedThrowingContinuation { continuation in
			self.evaluateJavaScript(jsGetMaxScrollSize) { result, error in
				var maxSize = CGSize.zero

				if let resultString = result as? String {
					let data = resultString.split(separator: ",").compactMap { CGFloat(Double($0)!) }
					if data.count == 2 {
						maxSize = CGSize(width: data[0], height: data[1])
					}
				}

				if let error = error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume(returning: maxSize)
				}
			}
		}
	}
}

public enum WebKitBrowserError: Error, LocalizedError {
	case missingHTML
	case printFailed
	/// WebKit reported a navigation failure; `underlying` is its error.
	case loadFailed(underlying: Error)
	/// The page never settled within ``WebKitBrowser/timeout``.
	case timedOut(seconds: TimeInterval)
	/// The web content process died before the page could be captured.
	case webContentProcessTerminated

	public var errorDescription: String? {
		switch self {
		case .missingHTML:
			return "The page produced no HTML"
		case .printFailed:
			return "The print operation did not produce a PDF"
		case .loadFailed(let underlying):
			return "The page failed to load: \(underlying.localizedDescription)"
		case .timedOut(let seconds):
			return "The page did not finish loading within \(Int(seconds)) seconds"
		case .webContentProcessTerminated:
			return "The web content process terminated before the page was captured"
		}
	}
}

// MARK: - Print Operation Helper

#if os(macOS)
/// Bridges NSPrintOperation's delegate callback to async/await. macOS-only:
/// there is no UIKit counterpart, and paginated export on iOS is tracked in #55.
@available(macOS 10.15, *)
private class PrintOperationHelper: NSObject {
	private var continuation: CheckedContinuation<Data, Error>?
	private var outputURL: URL?

	@MainActor
	func run(_ operation: NSPrintOperation, outputURL: URL) async throws -> Data {
		self.outputURL = outputURL

		return try await withCheckedThrowingContinuation { continuation in
			self.continuation = continuation
			operation.runModal(
				for: NSWindow(),
				delegate: self,
				didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
				contextInfo: nil
			)
		}
	}

	@objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
		guard let outputURL else {
			continuation?.resume(throwing: WebKitBrowserError.printFailed)
			return
		}

		if success, FileManager.default.fileExists(atPath: outputURL.path) {
			do {
				let data = try Data(contentsOf: outputURL)
				try? FileManager.default.removeItem(at: outputURL)
				continuation?.resume(returning: data)
			} catch {
				try? FileManager.default.removeItem(at: outputURL)
				continuation?.resume(throwing: error)
			}
		} else {
			try? FileManager.default.removeItem(at: outputURL)
			continuation?.resume(throwing: WebKitBrowserError.printFailed)
		}
	}
}

#endif

#endif
