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

	/// Exports the rendered page as paginated PDF data, through the platform's
	/// print pipeline.
	///
	/// Unlike `exportPDFData` (which produces a single continuous page),
	/// this method uses the print pipeline and respects CSS `@page` rules
	/// for page size, margins, and page breaks.
	///
	/// macOS drives that pipeline with `NSPrintOperation` and iOS with
	/// `UIPrintPageRenderer`. They are different APIs onto the *same* WebKit
	/// paginator, so the page counts match — measured, not assumed: see
	/// `webKitBrowserPaginatesForcedPageBreaks`, which asserts the same numbers
	/// on both platforms.
	///
	/// - Parameter paperSize: The paper size in points (e.g. 595.28×841.89 for A4).
	/// - Returns: Paginated PDF data.
	@MainActor
	@available(macOS 11.0, *)
	package func exportPaginatedPDFData(paperSize: CGSize) async throws -> Data {
		let webView = try await loadedWebView()
		try await prepareTablesForPrinting(in: webView, paperSize: paperSize)
		#if canImport(UIKit)
		return try Self.paginatedPDFData(from: webView, paperSize: paperSize)
		#else
		return try await Self.paginatedPDFData(from: webView, paperSize: paperSize)
		#endif
	}

	/// WebKit's print paginator neither repeats table headers nor keeps a row's
	/// border and contents together. Split ordinary tables into page-sized table
	/// fragments immediately before printing, while print-media styles are active.
	/// Each continuation is a real table with its own cloned `thead`, so the result
	/// does not depend on WebKit implementing table fragmentation correctly.
	@MainActor
	private func prepareTablesForPrinting(in webView: WKWebView, paperSize: CGSize) async throws {
		let script = """
		(function() {
			const paperWidth = \(paperSize.width);
			const paperHeight = \(paperSize.height);

			function lengthInPoints(value, reference) {
				if (!value) return 0;
				const match = String(value).trim().match(/^(-?[0-9]*\\.?[0-9]+)\\s*(px|pt|pc|in|cm|mm|q|%)?$/i);
				if (!match) return 0;
				const amount = parseFloat(match[1]);
				switch ((match[2] || 'px').toLowerCase()) {
				case 'pt': return amount;
				case 'pc': return amount * 12;
				case 'in': return amount * 72;
				case 'cm': return amount * 72 / 2.54;
				case 'mm': return amount * 72 / 25.4;
				case 'q': return amount * 72 / 101.6;
				case '%': return amount * reference / 100;
				default: return amount * 0.75;
				}
			}

			function pageMargins() {
				let values = ['0', '0', '0', '0'];
				function apply(style) {
					if (style.margin) {
						const parts = style.margin.trim().split(/\\s+/);
						if (parts.length === 1) values = [parts[0], parts[0], parts[0], parts[0]];
						if (parts.length === 2) values = [parts[0], parts[1], parts[0], parts[1]];
						if (parts.length === 3) values = [parts[0], parts[1], parts[2], parts[1]];
						if (parts.length >= 4) values = parts.slice(0, 4);
					}
					if (style.marginTop) values[0] = style.marginTop;
					if (style.marginRight) values[1] = style.marginRight;
					if (style.marginBottom) values[2] = style.marginBottom;
					if (style.marginLeft) values[3] = style.marginLeft;
				}

				function visit(rules) {
					for (const rule of Array.from(rules || [])) {
						if (rule.type === CSSRule.PAGE_RULE && !rule.selectorText) apply(rule.style);
						if (rule.cssRules) visit(rule.cssRules);
					}
				}

				for (const sheet of Array.from(document.styleSheets)) {
					try { visit(sheet.cssRules); } catch (_) { /* cross-origin stylesheet */ }
				}
				return {
					top: lengthInPoints(values[0], paperHeight),
					right: lengthInPoints(values[1], paperWidth),
					bottom: lengthInPoints(values[2], paperHeight),
					left: lengthInPoints(values[3], paperWidth)
				};
			}

			function paginatedOffset(table, pageHeight, pageWidth) {
				const body = document.body;
				const savedBodyStyle = body.getAttribute('style');
				const marker = document.createElement('div');
				marker.style.setProperty('display', 'block', 'important');
				marker.style.setProperty('height', '0', 'important');
				marker.style.setProperty('margin', '0', 'important');
				marker.style.setProperty('padding', '0', 'important');
				marker.style.setProperty('border', '0', 'important');
				marker.style.setProperty('break-before', 'auto', 'important');
				marker.style.setProperty('break-after', 'auto', 'important');
				table.parentNode.insertBefore(marker, table);
				const tableGap = table.getBoundingClientRect().top - marker.getBoundingClientRect().top;
				const forcedBreaks = [];
				const forcedValues = new Set(['page', 'always', 'left', 'right', 'recto', 'verso']);
				for (const element of Array.from(body.querySelectorAll('*'))) {
					const style = getComputedStyle(element);
					if (forcedValues.has(style.breakBefore) || forcedValues.has(style.breakAfter)) {
						forcedBreaks.push([element, element.getAttribute('style')]);
						if (forcedValues.has(style.breakBefore)) {
							element.style.setProperty('break-before', 'column', 'important');
						}
						if (forcedValues.has(style.breakAfter)) {
							element.style.setProperty('break-after', 'column', 'important');
						}
					}
				}

				// A fixed-height multicolumn body uses WebKit's fragmentation layout.
				// The marker's column reveals the table's position after pagination
				// without letting the table's own fragmentation move the measurement.
				body.style.setProperty('height', pageHeight + 'px', 'important');
				body.style.setProperty('width', pageWidth + 'px', 'important');
				body.style.setProperty('column-width', pageWidth + 'px', 'important');
				body.style.setProperty('column-gap', '0', 'important');
				body.style.setProperty('column-fill', 'auto', 'important');
				const bodyTop = body.getBoundingClientRect().top;
				const offset = marker.getBoundingClientRect().top - bodyTop + tableGap;

				if (savedBodyStyle === null) body.removeAttribute('style');
				else body.setAttribute('style', savedBodyStyle);
				for (const [element, savedStyle] of forcedBreaks) {
					if (savedStyle === null) element.removeAttribute('style');
					else element.setAttribute('style', savedStyle);
				}
				marker.remove();
				return Math.max(0, Math.min(pageHeight, offset));
			}

			function fragmentTable(table, pageHeight, pageWidth) {
				const head = Array.from(table.children).find(element => element.tagName === 'THEAD');
				const bodies = Array.from(table.children).filter(element => element.tagName === 'TBODY');
				if (!head || bodies.length !== 1 || table.tFoot || table.dataset.swiftTextPaginated) return;

				const rows = Array.from(bodies[0].rows);
				if (rows.length < 2 || rows.some(row => row.querySelector('[rowspan]'))) return;

				const tableRect = table.getBoundingClientRect();
				const width = tableRect.width;
				const style = getComputedStyle(table);
				const parent = table.parentNode;
				const anchor = table.nextSibling;
				const caption = Array.from(table.children).find(element => element.tagName === 'CAPTION');

				function makeFragment(chunkRows, index, measuring) {
					const fragment = table.cloneNode(false);
					fragment.dataset.swiftTextPaginated = 'true';
					if (index > 0) fragment.removeAttribute('id');
					fragment.style.width = width + 'px';
					fragment.style.boxSizing = 'border-box';
					fragment.style.marginTop = index === 0 ? style.marginTop : '0';
					fragment.style.marginBottom = '0';
					fragment.style.breakBefore = 'auto';
					fragment.style.pageBreakBefore = 'auto';
					if (measuring) {
						fragment.style.setProperty('position', 'absolute', 'important');
						fragment.style.setProperty('visibility', 'hidden', 'important');
						fragment.style.margin = '0';
					}

					if (index === 0 && caption) fragment.appendChild(caption.cloneNode(true));
					for (const child of Array.from(table.children)) {
						if (child.tagName === 'COLGROUP') fragment.appendChild(child.cloneNode(true));
					}
					fragment.appendChild(head.cloneNode(true));
					const body = bodies[0].cloneNode(false);
					body.removeAttribute('id');
					for (const row of chunkRows) {
						const copy = row.cloneNode(true);
						copy.style.breakInside = 'avoid';
						copy.style.pageBreakInside = 'avoid';
						body.appendChild(copy);
					}
					fragment.appendChild(body);
					return fragment;
				}

				let capacity = pageHeight - paginatedOffset(table, pageHeight, pageWidth);
				if (tableRect.height <= capacity + 0.5) return;

				// Measuring a real fragment includes captions, table decorations,
				// border spacing, and selector-dependent row sizes.
				function measuredHeight(chunkRows, index) {
					const probe = makeFragment(chunkRows, index, true);
					parent.insertBefore(probe, table);
					const height = probe.getBoundingClientRect().height;
					probe.remove();
					return height;
				}

				let startsOnNewPage = false;
				if (measuredHeight([rows[0]], 0) > capacity + 0.5) {
					startsOnNewPage = true;
					capacity = pageHeight;
				}

				const chunks = [];
				let chunk = [];
				for (const row of rows) {
					if (chunk.length && measuredHeight(chunk.concat(row), chunks.length) > capacity + 0.5) {
						chunks.push(chunk);
						chunk = [];
						capacity = pageHeight;
					}
					chunk.push(row);
				}
				if (chunk.length) chunks.push(chunk);
				if (chunks.length < 2 && !startsOnNewPage) return;

				const fragments = chunks.map((chunkRows, index) => {
					const fragment = makeFragment(chunkRows, index, false);
					fragment.style.marginBottom = index === chunks.length - 1 ? style.marginBottom : '0';
					return fragment;
				});

				for (const [index, fragment] of fragments.entries()) {
					if (index > 0 || startsOnNewPage) {
						// WebKit can apply a break on a collapsed table after laying out
						// its header, which leaves that header on the preceding page. A
						// block marker establishes the page boundary before table layout.
						const marker = document.createElement('div');
						marker.dataset.swiftTextPageBreak = 'true';
						marker.style.setProperty('display', 'block', 'important');
						marker.style.setProperty('height', '1px', 'important');
						marker.style.setProperty('margin', '0 0 -1px', 'important');
						marker.style.setProperty('padding', '0', 'important');
						marker.style.setProperty('border', '0', 'important');
						marker.style.setProperty('overflow', 'hidden', 'important');
						marker.style.setProperty('break-before', 'page', 'important');
						marker.style.setProperty('page-break-before', 'always', 'important');
						parent.insertBefore(marker, anchor);
					}
					parent.insertBefore(fragment, anchor);
				}
				table.remove();
			}

			function prepare() {
				const margins = pageMargins();
				const printableWidth = paperWidth - margins.left - margins.right;
				const printableHeight = paperHeight - margins.top - margins.bottom;
				const layoutWidth = document.documentElement.clientWidth;
				if (printableWidth <= 0 || printableHeight <= 0 || layoutWidth <= 0) return;
				const pageHeight = printableHeight * layoutWidth / printableWidth;
				for (const table of Array.from(document.querySelectorAll('table'))) {
					fragmentTable(table, pageHeight, layoutWidth);
				}
			}

			window.addEventListener('beforeprint', prepare, { once: true });
		})();
		"""
		_ = try await webView.evaluateJavaScript(script)
	}

	#if canImport(UIKit)
	/// Renders the loaded page through UIKit's print pipeline.
	///
	/// `UIPrintPageRenderer` is the paginator `UIPrintInteractionController` runs
	/// when a user prints, and `viewPrintFormatter()` is WebKit's own print
	/// formatter — so this reaches the same machinery, and honours the same CSS
	/// fragmentation rules, as the `NSPrintOperation` path on macOS.
	///
	/// Simpler than the macOS side, in fact: no delegate callback to bridge to
	/// async, and no temp file, so there is no iOS counterpart to
	/// `PrintOperationHelper`.
	@MainActor
	private static func paginatedPDFData(from webView: WKWebView, paperSize: CGSize) throws -> Data {
		let pageRenderer = UIPrintPageRenderer()
		pageRenderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)

		// `paperRect` and `printableRect` are read-only, so KVC is the only way to
		// set them. Universally done, but not a documented API contract — these two
		// lines are the ones that would break if UIKit stopped backing them with
		// KVC, and the `guard` below is what would turn that into a clear error
		// rather than a zero-page PDF.
		let paperRect = CGRect(origin: .zero, size: paperSize)
		pageRenderer.setValue(NSValue(cgRect: paperRect), forKey: "paperRect")
		pageRenderer.setValue(NSValue(cgRect: paperRect), forKey: "printableRect")

		// Reading `numberOfPages` is what runs pagination.
		let pageCount = pageRenderer.numberOfPages
		guard pageCount > 0 else {
			throw WebKitBrowserError.printFailed
		}

		// `UIGraphicsPDFRenderer` rather than `UIGraphicsBeginPDFContextToData`:
		// same output, non-legacy API.
		let pdfRenderer = UIGraphicsPDFRenderer(bounds: paperRect)
		return pdfRenderer.pdfData { context in
			for page in 0 ..< pageCount {
				context.beginPage()
				pageRenderer.drawPage(at: page, in: pageRenderer.paperRect)
			}
		}
	}
	#else
	/// Renders the loaded page through AppKit's print pipeline.
	@MainActor
	private static func paginatedPDFData(from webView: WKWebView, paperSize: CGSize) async throws -> Data {
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

#if !canImport(UIKit)
/// Bridges NSPrintOperation's delegate callback to async/await. AppKit-only:
/// the UIKit pipeline needs no such bridge — `UIPrintPageRenderer` paginates
/// synchronously and draws straight into a PDF context.
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
