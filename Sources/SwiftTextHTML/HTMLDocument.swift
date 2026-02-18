import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public final class HTMLDocument
{
	public let root: DOMElement
	public let baseURL: URL?

	public init(data: Data, baseURL: URL? = nil) async throws
	{
		self.baseURL = baseURL
		let builder = try await DomBuilder(html: data, baseURL: baseURL)
		guard let root = builder.root else {
			throw HTMLDocumentError.missingRoot
		}
		self.root = root
	}

	public func markdown() -> String
	{
		root.markdown(imageResolver: resolveMarkdownImageSource).trimmingCharacters(in: .whitespacesAndNewlines)
	}

	public func markdown(saveImagesAt folderURL: URL?) async throws -> String
	{
		guard let folderURL else {
			return markdown()
		}

		var sources: [String] = []
		collectImageSources(from: root, into: &sources)
		let imageMap = try await downloadImages(sources: sources, to: folderURL)
		return root.markdown(imageResolver: { source in
			imageMap[source]
		}).trimmingCharacters(in: .whitespacesAndNewlines)
	}

	public func text() -> String
	{
		root.text().trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private func collectImageSources(from node: DOMNode, into sources: inout [String]) {
		guard let element = node as? DOMElement else {
			return
		}

		if element.name == "img",
		   let src = element.attributes["src"] as? String,
		   !src.isEmpty,
		   !src.hasPrefix("data:")
		{
			sources.append(src)
		}

		for child in element.children {
			collectImageSources(from: child, into: &sources)
		}
	}

	private func downloadImages(sources: [String], to folderURL: URL) async throws -> [String: String] {
		guard !sources.isEmpty else {
			return [:]
		}

		try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

		var seenSources = Set<String>()
		var usedNames = Set<String>()
		var mapping: [String: String] = [:]
		var index = 1

		for source in sources {
			guard !seenSources.contains(source) else { continue }
			seenSources.insert(source)

			guard let resolvedURL = resolveImageURL(source) else { continue }
			let baseName = suggestedFileName(for: resolvedURL, fallbackIndex: index)
			let uniqueName = uniquifyFileName(baseName, usedNames: &usedNames)
			mapping[source] = uniqueName
			index += 1

			let data = try await fetchData(from: resolvedURL)
			let destination = folderURL.appendingPathComponent(uniqueName)
			try data.write(to: destination)
		}

		return mapping
	}

	private func resolveImageURL(_ source: String) -> URL? {
		if let url = URL(string: source), url.scheme != nil {
			return url
		}

		if let baseURL {
			return URL(string: source, relativeTo: baseURL)?.absoluteURL
		}

		return URL(string: source)
	}

	private func resolveMarkdownImageSource(_ source: String) -> String? {
		guard !source.isEmpty else {
			return source
		}

		if source.hasPrefix("data:") || source.hasPrefix("//") {
			return source
		}

		if let url = URL(string: source), url.scheme != nil {
			return source
		}

		guard let baseURL else {
			return source
		}

		return URL(string: source, relativeTo: baseURL)?.absoluteURL.absoluteString ?? source
	}

	private func suggestedFileName(for url: URL, fallbackIndex: Int) -> String {
		let candidate = url.lastPathComponent
		if !candidate.isEmpty {
			return candidate
		}
		return "image-\(fallbackIndex)"
	}

	private func uniquifyFileName(_ name: String, usedNames: inout Set<String>) -> String {
		if !usedNames.contains(name) {
			usedNames.insert(name)
			return name
		}

		let ext = (name as NSString).pathExtension
		let base = (name as NSString).deletingPathExtension
		var counter = 2
		var candidate: String
		repeat {
			if ext.isEmpty {
				candidate = "\(base)-\(counter)"
			} else {
				candidate = "\(base)-\(counter).\(ext)"
			}
			counter += 1
		} while usedNames.contains(candidate)

		usedNames.insert(candidate)
		return candidate
	}

	private func fetchData(from url: URL) async throws -> Data {
		try await withCheckedThrowingContinuation { continuation in
			let task = URLSession.shared.dataTask(with: url) { data, response, error in
				if let error {
					continuation.resume(throwing: error)
					return
				}

				guard let data else {
					continuation.resume(throwing: HTMLDocumentError.missingImageData(url))
					return
				}

				continuation.resume(returning: data)
			}
			task.resume()
		}
	}
}

public enum HTMLDocumentError: Error
{
	case missingRoot
	case missingImageData(URL)
}
