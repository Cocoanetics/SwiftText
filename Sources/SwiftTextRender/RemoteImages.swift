//  RemoteImages.swift
//  SwiftTextRender
//
//  Fetches the images a document references by URL before layout, which stays
//  synchronous. `renderPDF` loads `http` and `https` sources with URLSession by
//  default — what an HTML email needs for its logos — and a caller can supply
//  its own loader (to resolve an email's `cid:` parts, say) or none at all to
//  render without touching the network.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Loads the bytes of an image a document references by URL.
public typealias ImageLoader = @Sendable (URL) async throws -> Data

/// Images loaded ahead of layout, by `<img src>` value: the bytes, or why
/// they could not be had.
public typealias LoadedImages = [String: Result<Data, any Error>]

/// Why the default image loader gave up on a URL.
public enum ImageLoadingError: Error, CustomStringConvertible {
	case unsupportedScheme(String)
	case httpStatus(Int)
	case tooLarge(Int)
	case noData

	public var description: String {
		switch self {
		case .unsupportedScheme(let scheme): return "the URL scheme '\(scheme)' is not supported"
		case .httpStatus(let status): return "the server answered HTTP \(status)"
		case .tooLarge(let bytes): return "the image is \(bytes) bytes, more than the \(HTMLRenderer.maximumRemoteImageBytes)-byte limit"
		case .noData: return "the server sent no data"
		}
	}
}

extension HTMLRenderer {
	/// The largest image the default loader accepts.
	public static let maximumRemoteImageBytes = 20 * 1024 * 1024

	/// How many images load at once.
	static let maximumConcurrentImageLoads = 6

	/// The default `RenderOptions.imageLoader`: fetches `http` and `https` URLs
	/// with URLSession, giving up on a server that stays silent for 15 seconds
	/// or an image larger than `maximumRemoteImageBytes`. Other schemes throw.
	public static let urlSessionImageLoader: ImageLoader = { url in
		let scheme = url.scheme?.lowercased() ?? ""
		guard scheme == "http" || scheme == "https" else { throw ImageLoadingError.unsupportedScheme(scheme) }
		var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
		// Only the formats the image decoder embeds. Content-negotiating CDNs
		// otherwise answer with WebP or AVIF.
		request.setValue("image/png,image/jpeg;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
		let (data, status) = try await fetch(request)
		if let status, !(200 ... 299).contains(status) {
			throw ImageLoadingError.httpStatus(status)
		}
		return data
	}

	/// The body and HTTP status of a request. The body is cut off, and the
	/// request cancelled, as soon as it exceeds `maximumRemoteImageBytes`, so a
	/// server cannot make the renderer buffer more than that. Uses URLSession's
	/// delegate API, which every platform's Foundation has.
	private static func fetch(_ request: URLRequest) async throws -> (Data, Int?) {
		let collector = BodyCollector()
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				collector.start(request, continuation: continuation)
			}
		} onCancel: {
			collector.cancel()
		}
	}

	/// Load every image the rendered document shows that layout cannot read
	/// itself — not inline `data:` URIs or local files — at most
	/// `maximumConcurrentImageLoads` at a time. Images inside `display: none`
	/// are skipped, which also spares the tracking pixels emails hide.
	static func loadImages(referencedBy root: StyledElement, baseURL: URL?, using loader: @escaping ImageLoader) async -> LoadedImages {
		var requests: [(source: String, url: URL)] = []
		var seen = Set<String>()
		func collect(_ element: StyledElement) {
			guard element.computedStyle.display != .none else { return }
			if element.localName == "img",
			   let source = element.attributeValue("src")?.trimmingCharacters(in: .whitespacesAndNewlines),
			   seen.insert(source).inserted,
			   let url = remoteImageURL(source, baseURL: baseURL) {
				requests.append((source, url))
			}
			for child in element.elementChildren { collect(child) }
		}
		collect(root)
		guard !requests.isEmpty else { return [:] }

		return await withTaskGroup(of: (String, Result<Data, any Error>).self) { group in
			var pending = requests[...]
			func startNext() {
				guard let request = pending.popFirst() else { return }
				group.addTask {
					do {
						return (request.source, .success(try await loader(request.url)))
					} catch {
						return (request.source, .failure(error))
					}
				}
			}
			for _ in 0 ..< maximumConcurrentImageLoads { startNext() }
			var results: LoadedImages = [:]
			for await (source, result) in group {
				results[source] = result
				startNext()
			}
			return results
		}
	}

	/// The URL an image source has to be fetched from, or `nil` when layout
	/// reads it directly: a `data:` URI, or a local path resolved against a
	/// local (or missing) base URL.
	static func remoteImageURL(_ source: String, baseURL: URL?) -> URL? {
		guard !source.isEmpty, !source.hasPrefix("data:") else { return nil }
		// Protocol-relative, as emails sometimes write them.
		if source.hasPrefix("//") { return URL(string: "https:" + source) }
		if let url = URL(string: source), let scheme = url.scheme, scheme.count > 1 {
			// A one-letter "scheme" is a Windows drive letter.
			return url.isFileURL ? nil : url
		}
		guard let baseURL, !baseURL.isFileURL,
		      let resolved = URL(string: source, relativeTo: baseURL)?.absoluteURL else { return nil }
		return resolved
	}
}

/// Collects a response body through a delegate-driven session, rejecting it
/// as soon as the declared or received size passes the limit.
private final class BodyCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
	private let lock = NSLock()
	private var data = Data()
	private var status: Int?
	private var continuation: CheckedContinuation<(Data, Int?), any Error>?
	private var session: URLSession?
	private var task: URLSessionDataTask?

	func start(_ request: URLRequest, continuation: CheckedContinuation<(Data, Int?), any Error>) {
		lock.lock()
		self.continuation = continuation
		let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
		let task = session.dataTask(with: request)
		self.session = session
		self.task = task
		lock.unlock()
		task.resume()
	}

	func cancel() {
		lock.lock()
		let task = self.task
		lock.unlock()
		task?.cancel()
	}

	private func finish(_ result: Result<(Data, Int?), any Error>) {
		lock.lock()
		let continuation = self.continuation
		self.continuation = nil
		let session = self.session
		self.session = nil
		lock.unlock()
		session?.invalidateAndCancel()
		continuation?.resume(with: result)
	}

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
	                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
		lock.lock()
		status = (response as? HTTPURLResponse)?.statusCode
		lock.unlock()
		let declared = response.expectedContentLength
		if declared > Int64(HTMLRenderer.maximumRemoteImageBytes) {
			completionHandler(.cancel)
			finish(.failure(ImageLoadingError.tooLarge(Int(clamping: declared))))
		} else {
			completionHandler(.allow)
		}
	}

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
		lock.lock()
		data.append(chunk)
		let size = data.count
		lock.unlock()
		if size > HTMLRenderer.maximumRemoteImageBytes {
			dataTask.cancel()
			finish(.failure(ImageLoadingError.tooLarge(size)))
		}
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
		lock.lock()
		let body = data
		let status = self.status
		lock.unlock()
		if let error {
			finish(.failure(error))
		} else if body.isEmpty {
			finish(.failure(ImageLoadingError.noData))
		} else {
			finish(.success((body, status)))
		}
	}
}
