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
	/// The body reached at least `bytes`, past `limit`, when the transfer was stopped.
	case tooLarge(bytes: Int, limit: Int)

	public var description: String {
		switch self {
		case .unsupportedScheme(let scheme): return "the URL scheme '\(scheme)' is not supported"
		case .httpStatus(let status): return "the server answered HTTP \(status)"
		case .tooLarge(let bytes, let limit): return "the image is at least \(bytes) bytes, more than the \(limit)-byte limit"
		}
	}
}

extension HTMLRenderer {
	/// The largest image the default loader accepts.
	public static let maximumRemoteImageBytes = 20 * 1024 * 1024

	/// How many images load at once.
	static let maximumConcurrentImageLoads = 6

	/// The default `RenderOptions.imageLoader`: fetches `http` and `https` URLs
	/// with URLSession, giving up on a server that stays silent for 15 seconds,
	/// a transfer that takes more than 30, or an image larger than
	/// `maximumRemoteImageBytes`. Other schemes throw.
	public static let urlSessionImageLoader: ImageLoader = { url in
		try await downloadImage(from: url)
	}

	/// Download an image, stopping the transfer as soon as its declared or
	/// received size passes `limit` — a hostile server cannot make the renderer
	/// buffer an endless body.
	static func downloadImage(from url: URL, limit: Int = maximumRemoteImageBytes,
	                          configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
		let scheme = url.scheme?.lowercased() ?? ""
		guard scheme == "http" || scheme == "https" else { throw ImageLoadingError.unsupportedScheme(scheme) }
		var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
		// Only the formats the image decoder embeds. Content-negotiating CDNs
		// otherwise answer with WebP or AVIF.
		request.setValue("image/png,image/jpeg;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
		configuration.timeoutIntervalForResource = 30
		let (data, status) = try await LimitedDownload(limit: limit).run(request, configuration: configuration)
		if let status, !(200 ... 299).contains(status) {
			throw ImageLoadingError.httpStatus(status)
		}
		return data
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

		@Sendable func load(_ request: (source: String, url: URL)) async -> (String, Result<Data, any Error>) {
			do {
				return (request.source, .success(try await loader(request.url)))
			} catch {
				return (request.source, .failure(error))
			}
		}

		// Tasks are added straight to `group` and results taken with `next()`:
		// adding them from a nested function that captured the group while a
		// `for await` loop iterated it lost every result in optimized builds,
		// so release binaries drew each remote image as a placeholder.
		return await withTaskGroup(of: (String, Result<Data, any Error>).self) { group in
			var pending = requests[...]
			for _ in 0 ..< maximumConcurrentImageLoads {
				guard let request = pending.popFirst() else { break }
				group.addTask { await load(request) }
			}
			var results: LoadedImages = [:]
			while let (source, result) = await group.next() {
				results[source] = result
				if let request = pending.popFirst() {
					group.addTask { await load(request) }
				}
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

/// One image download that is cut off the moment its body outgrows the limit.
///
/// URLSession's delegate API, unlike its completion handlers, sees the body
/// arrive chunk by chunk, and it is the same on every platform's Foundation.
/// URLSession calls the delegate on its own queue; the lock guards the state
/// it shares with the task that awaits the result.
private final class LimitedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
	private typealias Outcome = Result<(Data, Int?), any Error>

	private let limit: Int
	private let lock = NSLock()
	private var received = Data()
	private var task: URLSessionDataTask?
	private var continuation: CheckedContinuation<(Data, Int?), any Error>?
	private var isCancelled = false

	init(limit: Int) {
		self.limit = limit
	}

	/// The body and HTTP status of `request`.
	func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (Data, Int?) {
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
				let task = session.dataTask(with: request)
				let cancelled = locked { () -> Bool in
					self.continuation = continuation
					self.task = task
					return isCancelled
				}
				if cancelled {
					task.cancel()
					finish(.failure(CancellationError()))
				} else {
					task.resume()
				}
				// Releases the session — and with it this delegate — once the task ends.
				session.finishTasksAndInvalidate()
			}
		} onCancel: {
			let task = locked { () -> URLSessionDataTask? in
				isCancelled = true
				return self.task
			}
			task?.cancel()
			finish(.failure(CancellationError()))
		}
	}

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		let size = locked { () -> Int in
			received.append(data)
			return received.count
		}
		let declared = dataTask.response?.expectedContentLength ?? -1
		guard size > limit || declared > Int64(limit) else { return }
		dataTask.cancel()
		finish(.failure(ImageLoadingError.tooLarge(bytes: max(size, Int(clamping: declared)), limit: limit)))
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
		if let error {
			finish(.failure(error))
		} else {
			let status = (task.response as? HTTPURLResponse)?.statusCode
			finish(.success((locked { received }, status)))
		}
	}

	/// Resume the waiting task exactly once; whatever comes after — the
	/// completion of a transfer this cancelled — is dropped.
	private func finish(_ outcome: Outcome) {
		let continuation = locked { () -> CheckedContinuation<(Data, Int?), any Error>? in
			defer { self.continuation = nil }
			return self.continuation
		}
		continuation?.resume(with: outcome)
	}

	private func locked<Value>(_ body: () -> Value) -> Value {
		lock.lock()
		defer { lock.unlock() }
		return body()
	}
}
