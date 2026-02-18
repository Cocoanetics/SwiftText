import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public final class HTMLToMarkdown
{
	private var url: URL?
	private var data: Data?

	public init(url: URL)
	{
		self.url = url
	}

	public init(data: Data, url: URL? = nil)
	{
		self.data = data
		self.url = url
	}

	public func markdown() async throws -> String
	{
		let htmlData = try await resolveData()
		let document = try await HTMLDocument(data: htmlData, baseURL: url)
		return document.markdown()
	}

	public func text() async throws -> String
	{
		let htmlData = try await resolveData()
		let document = try await HTMLDocument(data: htmlData, baseURL: url)
		return document.text()
	}

	private func resolveData() async throws -> Data
	{
		if let data {
			return data
		}

		guard let url else {
			throw HTMLToMarkdownError.missingSource
		}

		if url.isFileURL {
			return try Data(contentsOf: url)
		}

		return try await fetchData(from: url)
	}

	private func fetchData(from url: URL) async throws -> Data
	{
		try await withCheckedThrowingContinuation { continuation in
			let task = URLSession.shared.dataTask(with: url) { data, response, error in
				if let error {
					continuation.resume(throwing: error)
					return
				}

				guard let data else {
					continuation.resume(throwing: HTMLToMarkdownError.missingSource)
					return
				}

				continuation.resume(returning: data)
			}
			task.resume()
		}
	}
}

public enum HTMLToMarkdownError: Error
{
	case missingSource
}
