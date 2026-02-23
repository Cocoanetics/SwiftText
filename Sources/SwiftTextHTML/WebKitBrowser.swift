#if os(macOS)
import AppKit
import Foundation
import WebKit

@available(macOS 10.15, *)
public class WebKitBrowser: NSObject, WKNavigationDelegate
{
	// MARK: - Public Properties

	public let url: URL

	// MARK: - Internal Properties
	private var webView: WKWebView!
	private var htmlResult: String?
	private var didLoad = false
	private var continuation: CheckedContinuation<String?, Never>?
	private var loadContinuation: CheckedContinuation<Void, Never>?
	private var htmlStringToLoad: String?
	private var fileURLToLoad: URL?
	private var readAccessRoot: URL?

	/// Optional frame size override. When set, the WKWebView is created
	/// with this size so content reflows to the target width (e.g. A4).
	public var frameSize: CGSize?

	/// When `true`, the webview frame is NOT resized to the scroll height
	/// after loading. This lets WebKit paginate content for PDF export.
	public var preserveFrameHeight = false

	// MARK: - Public Interface

	public init(url: URL)
	{
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
	public init(htmlString: String, baseURL: URL? = nil)
	{
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
	public init(fileURL: URL, readAccessRoot: URL)
	{
		self.url = fileURL
		self.htmlStringToLoad = nil
		self.fileURLToLoad = fileURL
		self.readAccessRoot = readAccessRoot
		super.init()
	}

	@MainActor
	public func waitForLoadCompletion() async
	{
		guard !didLoad else
		{
			return
		}

		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			loadContinuation = continuation
			self.load()
		}
	}

	@MainActor
	@available(macOS 12.0, *)
	public func exportPDF(to outputURL: URL) async throws
	{
		if !didLoad
		{
			await waitForLoadCompletion()
		}

		let data = try await webView.pdf()
		try data.write(to: outputURL)
	}

	/// Exports the rendered page as PDF data.
	///
	/// - Parameter configuration: Optional `WKPDFConfiguration`; defaults to capturing the full page.
	/// - Returns: PDF data for the rendered content.
	@MainActor
	@available(macOS 12.0, *)
	public func exportPDFData(configuration: WKPDFConfiguration = WKPDFConfiguration()) async throws -> Data
	{
		if !didLoad
		{
			await waitForLoadCompletion()
		}

		return try await webView.pdf(configuration: configuration)
	}

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
	public func exportPaginatedPDFData(paperSize: CGSize) async throws -> Data
	{
		if !didLoad
		{
			await waitForLoadCompletion()
		}

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

	@MainActor
	public func exportHTML(to outputURL: URL) async throws
	{
		guard let html = await html() else {
			throw WebKitBrowserError.missingHTML
		}
		try html.write(to: outputURL, atomically: true, encoding: .utf8)
	}

	// MARK: - Helpers
	@MainActor
	private func load()
	{
		let config = WKWebViewConfiguration()
		let contentController = WKUserContentController()
		contentController.add(self, name: "pageLoaded")
		config.userContentController = contentController

		let initialSize = frameSize ?? CGSize(width: 800, height: 600)
		webView = WKWebView(frame: CGRect(origin: .zero, size: initialSize), configuration: config)
		webView.navigationDelegate = self

		if let html = htmlStringToLoad
		{
			webView.loadHTMLString(html, baseURL: url == URL(string: "about:blank") ? nil : url)
		}
		else if let fileURL = fileURLToLoad, let readRoot = readAccessRoot
		{
			webView.loadFileURL(fileURL, allowingReadAccessTo: readRoot)
		}
		else
		{
			let urlRequest = URLRequest(url: url)
			webView.load(urlRequest)
		}
	}

	@MainActor
	private func updateWebView(size: CGSize)
	{
		let width = frameSize?.width ?? 800
		self.webView.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
		self.webView.layout()
	}

	// MARK: - WKNavigationDelegate
	public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!)
	{
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

		webView.evaluateJavaScript(js) { (result, error) in
			if let error = error {
				print("Error injecting JavaScript: \(error)")
			}
		}
	}
}

@available(macOS 10.15, *)
extension WebKitBrowser: WKScriptMessageHandler
{
	@objc public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage)
	{
		guard message.name == "pageLoaded", let html = message.body as? String else
		{
			return
		}

		didLoad = true
		htmlResult = html

		Task
		{
			do {
				if !preserveFrameHeight {
					let maxSize = try await webView.getMaxScrollSize()
					self.updateWebView(size: maxSize)
				}

				self.loadContinuation?.resume()
				self.loadContinuation = nil

			} catch {
				self.loadContinuation?.resume()
				self.loadContinuation = nil
			}
		}

		continuation?.resume(returning: html)
		continuation = nil
	}
}

@available(macOS 10.15, *)
extension WebKitBrowser
{
	public func html() async -> String?
	{
		if didLoad {
			return htmlResult
		}

		await waitForLoadCompletion()
		return htmlResult
	}
}

@available(macOS 10.15, *)
extension WKWebView
{
	func getMaxScrollSize() async throws -> CGSize
	{
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

public enum WebKitBrowserError: Error
{
	case missingHTML
	case printFailed
}

// MARK: - Print Operation Helper

/// Bridges NSPrintOperation's delegate callback to async/await.
@available(macOS 10.15, *)
private class PrintOperationHelper: NSObject
{
	private var continuation: CheckedContinuation<Data, Error>?
	private var outputURL: URL?

	@MainActor
	func run(_ operation: NSPrintOperation, outputURL: URL) async throws -> Data
	{
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

	@objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?)
	{
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
