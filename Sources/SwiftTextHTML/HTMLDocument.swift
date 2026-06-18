import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public final class HTMLDocument {
	public let root: DOMElement
	public let baseURL: URL?

	public init(data: Data, baseURL: URL? = nil, encoding: String.Encoding? = nil) async throws {
		self.baseURL = baseURL
		let builder = try await DomBuilder(html: data, baseURL: baseURL, encoding: encoding)
		guard let root = builder.root else {
			throw HTMLDocumentError.missingRoot
		}
		self.root = root
	}

	private var contentRoot: DOMElement {
		// Prefer proper <html>...</html> content when present. Some email clients append
		// footers after </html>; we intentionally ignore those for Markdown extraction.
		if root.name.lowercased() == "document" {
			if let html = root.children.compactMap({ $0 as? DOMElement }).first(where: { $0.name.lowercased() == "html" }) {
				return html
			}
		}
		return root
	}

	public func markdown() -> String {
		contentRoot.markdown(imageResolver: resolveMarkdownImageSource).trimmingCharacters(in: .whitespacesAndNewlines)
	}

	public func markdown(saveImagesAt folderURL: URL?) async throws -> String {
		guard let folderURL else {
			return markdown()
		}

		var sources: [String] = []
		collectImageSources(from: contentRoot, into: &sources)
		let imageMap = try await downloadImages(sources: sources, to: folderURL)
		return root.markdown(imageResolver: { source in
			imageMap[source]
		}).trimmingCharacters(in: .whitespacesAndNewlines)
	}

	public func text() -> String {
		contentRoot.text().trimmingCharacters(in: .whitespacesAndNewlines)
	}

	// MARK: - Stylesheets

	/// The document's inline `<style>` CSS, in document order. A convenience
	/// forwarding to the root element; external `<link>` sheets are not fetched
	/// (use ``resolvedStyleSheets()`` for that).
	public func styleSheets() -> [String] {
		root.styleSheets()
	}

	/// All of the document's stylesheets in document order — inline `<style>`
	/// blocks and the contents of `<link rel="stylesheet">`, resolved against
	/// the base URL and fetched. Unreachable or undecodable links are skipped,
	/// the way browsers ignore a failed stylesheet load.
	public func resolvedStyleSheets() async -> [String] {
		var sheets: [String] = []
		for source in root.styleSheetSources() {
			switch source {
			case .inline(let css):
				sheets.append(css)

			case .link(let href):
				if let css = await fetchStyleSheet(href: href) {
					sheets.append(css)
				}
			}
		}
		return sheets
	}

	private func fetchStyleSheet(href: String) async -> String? {
		if href.lowercased().hasPrefix("data:") {
			return Self.decodeTextDataURL(href)
		}

		guard let url = resolveURL(href),
		      let data = try? await fetchData(from: url)
		else {
			return nil
		}
		return String(data: data, encoding: .utf8)
	}

	/// Decode a `data:` URL carrying text (e.g. `data:text/css,...` or its
	/// `;base64` form) to its string payload.
	private static func decodeTextDataURL(_ uri: String) -> String? {
		guard let comma = uri.firstIndex(of: ",") else { return nil }
		let meta = uri[uri.startIndex ..< comma].lowercased()
		let payload = String(uri[uri.index(after: comma)...])
		if meta.contains(";base64") {
			guard let data = Data(base64Encoded: payload) else { return nil }
			return String(data: data, encoding: .utf8)
		}
		return payload.removingPercentEncoding ?? payload
	}

	private func collectImageSources(from node: DOMNode, into sources: inout [String]) {
		guard let element = node as? DOMElement else {
			return
		}

		if element.name == "img",
		   let src = element.attributes["src"] as? String,
		   !src.isEmpty,
		   !src.hasPrefix("data:") {
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

			guard let resolvedURL = resolveURL(source) else { continue }
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

	/// Resolve an href/src against the document base URL (absolute URLs pass
	/// through unchanged). Used for both image sources and stylesheet links.
	private func resolveURL(_ source: String) -> URL? {
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
			let task = URLSession.shared.dataTask(with: url) { data, _, error in
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

public enum HTMLDocumentError: Error {
	case missingRoot
	case missingImageData(URL)
}
