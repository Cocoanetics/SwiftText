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
		guard data.count <= maximumRemoteImageBytes else { throw ImageLoadingError.tooLarge(data.count) }
		return data
	}

	/// The body and HTTP status of a request, through URLSession's
	/// completion-handler API, which every platform's Foundation has (the async
	/// one is missing from some).
	private static func fetch(_ request: URLRequest) async throws -> (Data, Int?) {
		try await withCheckedThrowingContinuation { continuation in
			let task = URLSession.shared.dataTask(with: request) { data, response, error in
				if let error {
					continuation.resume(throwing: error)
				} else if let data {
					continuation.resume(returning: (data, (response as? HTTPURLResponse)?.statusCode))
				} else {
					continuation.resume(throwing: ImageLoadingError.noData)
				}
			}
			task.resume()
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
