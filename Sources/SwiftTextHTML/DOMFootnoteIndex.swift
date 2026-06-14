import Foundation

/// Detects footnote structures in a parsed HTML DOM and supplies the mapping
/// needed to restore Markdown footnote syntax (`[^id]` references and
/// `[^id]: …` definitions). swift-markdown has no footnote AST node, so footnotes
/// are reconstructed as text by ``DOMMarkupConverter`` using this index.
///
/// Detection is layered:
///
/// 1. **Attribute fast-path** — recognizes the markers common generators emit
///    (GitHub: `data-footnote-ref` / `data-footnotes`; Pandoc: `role="doc-noteref"`
///    / `role="doc-endnotes"` / `class="footnote-*"`; this project:
///    `class="footnote-definition"`).
/// 2. **Structural fallback (attribute-free)** — a reference is an `<a href="#X">`
///    whose visible text is a number and whose target `#X` either links back to
///    the reference (reciprocal linking), is the *n*-th item of a list, or leads
///    with an echoed marker (`[n]:`). This catches hand-rolled footnotes with no
///    class/role/data markers — only `href`/`id` (the link mechanism itself) and
///    document structure are used.
///
/// `nil` is returned when no footnotes are found, so the converter behaves exactly
/// as before on ordinary documents.
struct DOMFootnoteIndex {
	/// Definition `id` (e.g. `fn-1`, `user-content-fn-1`) → emitted label (`1`).
	let labelForID: [String: String]
	/// `id`s of the reference anchors. Links pointing at these are backrefs and
	/// are dropped from definition bodies.
	let refIDs: Set<String>
	/// Container/definition nodes suppressed from normal block rendering.
	let skip: Set<ObjectIdentifier>
	/// Definitions to append at the end of the document, in document order.
	let orderedDefinitions: [(label: String, body: DOMElement)]

	static func build(from root: DOMElement) -> DOMFootnoteIndex? {
		var scanner = FootnoteScanner()
		return scanner.scan(root)
	}

	// MARK: - Marker helpers (shared with DOMMarkupConverter)

	/// True when `string` is exactly a footnote marker token for `label`, e.g.
	/// `[1]`, `[1]:`, `1.`, `1:`, `1)`, or bare `1`.
	static func isMarkerToken(_ string: String, label: String) -> Bool {
		var token = string.trimmingCharacters(in: .whitespaces)
		if token.hasPrefix("["), let close = token.firstIndex(of: "]") {
			let inner = String(token[token.index(after: token.startIndex)..<close])
			let after = token[token.index(after: close)...].trimmingCharacters(in: .whitespaces)
			return inner == label && (after.isEmpty || after == ":")
		}
		if let last = token.last, ".:)".contains(last) { token.removeLast() }
		return token == label
	}

	/// If `text` begins with a footnote marker for `label`, returns the remainder
	/// with the marker (and following separator/space) removed; otherwise `nil`.
	static func strippedMarkerPrefix(_ text: String, label: String) -> String? {
		let trimmed = String(text.drop { $0 == " " })
		for prefix in ["[\(label)]:", "[\(label)]", "\(label).", "\(label):", "\(label))"] where trimmed.hasPrefix(prefix) {
			return String(trimmed.dropFirst(prefix.count).drop { $0 == " " })
		}
		return nil
	}

	/// True for the backref glyphs definitions trail with (`↩`, `↩︎`, `↑`, …).
	static func isBackrefGlyph(_ string: String) -> Bool {
		let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty || ["↩", "↩\u{FE0E}", "↑", "⤴", "⮐", "^"].contains(trimmed)
	}
}

// MARK: - Scanner

private struct FootnoteScanner {
	private var byID: [String: DOMElement] = [:]
	private var parents: [ObjectIdentifier: DOMElement] = [:]
	private var order: [ObjectIdentifier: Int] = [:]
	private var counter = 0

	mutating func scan(_ root: DOMElement) -> DOMFootnoteIndex? {
		indexTree(root, parent: nil)

		// 1. Accept references → label per definition id, reference ids.
		var labelForID: [String: String] = [:]
		var refIDs: Set<String> = []
		collectReferences(in: root, labelForID: &labelForID, refIDs: &refIDs)
		guard !labelForID.isEmpty else { return nil }

		// 2. Suppress containers, gather the ordered definition list.
		var skip: Set<ObjectIdentifier> = []
		var processedContainers: Set<ObjectIdentifier> = []
		var seenDef: Set<ObjectIdentifier> = []
		var items: [(order: Int, label: String, body: DOMElement)] = []

		for defID in labelForID.keys {
			guard let def = byID[defID] else { continue }
			let container = containerToSkip(for: def)
			guard processedContainers.insert(ObjectIdentifier(container)).inserted else { continue }

			skip.insert(ObjectIdentifier(container))
			if let hr = precedingHR(of: container) { skip.insert(ObjectIdentifier(hr)) }

			for item in memberDefinitions(of: container, fallback: def) {
				guard seenDef.insert(ObjectIdentifier(item)).inserted else { continue }
				let id = item.attributes["id"] as? String
				let label = (id.flatMap { labelForID[$0] }) ?? numberFromID(item) ?? String(items.count + 1)
				items.append((order[ObjectIdentifier(item)] ?? 0, label, item))
			}
		}

		items.sort { $0.order < $1.order }
		return DOMFootnoteIndex(
			labelForID: labelForID,
			refIDs: refIDs,
			skip: skip,
			orderedDefinitions: items.map { (label: $0.label, body: $0.body) }
		)
	}

	// MARK: Indexing

	private mutating func indexTree(_ element: DOMElement, parent: DOMElement?) {
		let oid = ObjectIdentifier(element)
		order[oid] = counter
		counter += 1
		if let parent { parents[oid] = parent }
		if let id = element.attributes["id"] as? String, byID[id] == nil { byID[id] = element }
		for child in element.children {
			if let childElement = child as? DOMElement { indexTree(childElement, parent: element) }
		}
	}

	// MARK: Reference acceptance

	private func collectReferences(in element: DOMElement, labelForID: inout [String: String], refIDs: inout Set<String>) {
		if element.name.lowercased() == "a",
		   let fragment = fragment(of: element),
		   let def = byID[fragment],
		   let n = markerNumber(of: element),
		   accept(reference: element, definition: def, number: n) {
			if labelForID[fragment] == nil { labelForID[fragment] = String(n) }
			if let rid = element.attributes["id"] as? String { refIDs.insert(rid) }
		}
		for child in element.children {
			if let childElement = child as? DOMElement {
				collectReferences(in: childElement, labelForID: &labelForID, refIDs: &refIDs)
			}
		}
	}

	private func accept(reference: DOMElement, definition def: DOMElement, number n: Int) -> Bool {
		// Attribute fast-path.
		if hasFootnoteRefAttribute(reference) || inFootnoteContainer(def) { return true }
		// Structural: reciprocal link (definition links back to the reference id).
		if let rid = reference.attributes["id"] as? String, containsBacklink(def, toFragment: rid) { return true }
		// Structural: definition is the n-th list item, or its text echoes the marker.
		if let parent = parents[ObjectIdentifier(def)], ["ol", "ul"].contains(parent.name.lowercased()) {
			if listItemIndex(of: def) == n || leadingMarkerMatches(rawText(of: def), number: n) { return true }
		}
		// Structural: a block definition whose leading text echoes the marker.
		if leadingMarkerMatches(rawText(of: def), number: n) { return true }
		return false
	}

	// MARK: Containers

	private func containerToSkip(for def: DOMElement) -> DOMElement {
		if let section = nearestAncestor(of: def, named: "section"), sectionLooksDedicated(section) {
			return section
		}
		if let parent = parents[ObjectIdentifier(def)], ["ol", "ul"].contains(parent.name.lowercased()) {
			return parent
		}
		return def
	}

	private func memberDefinitions(of container: DOMElement, fallback def: DOMElement) -> [DOMElement] {
		switch container.name.lowercased() {
		case "ol", "ul":
			return listItems(of: container)
		case "section":
			let items = allListItems(under: container)
			return items.isEmpty ? [def] : items
		default:
			return [def]
		}
	}

	private func sectionLooksDedicated(_ section: DOMElement) -> Bool {
		let allowed: Set<String> = ["hr", "ol", "ul", "h1", "h2", "h3", "h4", "h5", "h6"]
		let children = section.children.compactMap { $0 as? DOMElement }
		return !children.isEmpty && children.allSatisfy { allowed.contains($0.name.lowercased()) }
	}

	private func precedingHR(of container: DOMElement) -> DOMElement? {
		guard let parent = parents[ObjectIdentifier(container)] else { return nil }
		let siblings = parent.children.compactMap { $0 as? DOMElement }
		guard let index = siblings.firstIndex(where: { $0 === container }), index > 0 else { return nil }
		let previous = siblings[index - 1]
		return previous.name.lowercased() == "hr" ? previous : nil
	}

	// MARK: DOM helpers

	private func fragment(of anchor: DOMElement) -> String? {
		guard let href = anchor.attributes["href"] as? String else { return nil }
		return URLComponents(string: href)?.fragment
	}

	private func markerNumber(of anchor: DOMElement) -> Int? {
		var token = rawText(of: anchor).trimmingCharacters(in: .whitespacesAndNewlines)
		if token.hasPrefix("["), token.hasSuffix("]"), token.count >= 2 {
			token = String(token.dropFirst().dropLast())
		}
		if let last = token.last, ".:)".contains(last) { token.removeLast() }
		token = token.trimmingCharacters(in: .whitespaces)
		return (!token.isEmpty && token.allSatisfy(\.isNumber)) ? Int(token) : nil
	}

	private func hasFootnoteRefAttribute(_ element: DOMElement) -> Bool {
		element.attributes["data-footnote-ref"] != nil
			|| (element.attributes["role"] as? String) == "doc-noteref"
			|| classList(of: element).contains("footnote-ref")
	}

	private func inFootnoteContainer(_ def: DOMElement) -> Bool {
		var current: DOMElement? = def
		while let element = current {
			if element.attributes["data-footnotes"] != nil { return true }
			if (element.attributes["role"] as? String) == "doc-endnotes" { return true }
			let classes = classList(of: element)
			if classes.contains("footnotes") || classes.contains("footnote-definition") { return true }
			current = parents[ObjectIdentifier(element)]
		}
		return false
	}

	private func containsBacklink(_ def: DOMElement, toFragment rid: String) -> Bool {
		var found = false
		forEachAnchor(in: def) { anchor in
			if fragment(of: anchor) == rid { found = true }
		}
		return found
	}

	private func listItemIndex(of def: DOMElement) -> Int? {
		guard let parent = parents[ObjectIdentifier(def)] else { return nil }
		let items = listItems(of: parent)
		return items.firstIndex { $0 === def }.map { $0 + 1 }
	}

	private func leadingMarkerMatches(_ text: String, number n: Int) -> Bool {
		let trimmed = text.drop { $0 == " " || $0 == "\n" }
		return ["[\(n)]", "\(n).", "\(n):", "\(n))"].contains { trimmed.hasPrefix($0) }
	}

	private func numberFromID(_ element: DOMElement) -> String? {
		guard let id = element.attributes["id"] as? String else { return nil }
		let digits = String(id.reversed().prefix { $0.isNumber }.reversed())
		return digits.isEmpty ? nil : digits
	}

	private func nearestAncestor(of element: DOMElement, named name: String) -> DOMElement? {
		var current = parents[ObjectIdentifier(element)]
		while let ancestor = current {
			if ancestor.name.lowercased() == name { return ancestor }
			current = parents[ObjectIdentifier(ancestor)]
		}
		return nil
	}

	private func listItems(of element: DOMElement) -> [DOMElement] {
		element.children.compactMap { $0 as? DOMElement }.filter { $0.name.lowercased() == "li" }
	}

	private func allListItems(under element: DOMElement) -> [DOMElement] {
		var result: [DOMElement] = []
		for child in element.children.compactMap({ $0 as? DOMElement }) {
			if ["ol", "ul"].contains(child.name.lowercased()) {
				result.append(contentsOf: listItems(of: child))
			} else {
				result.append(contentsOf: allListItems(under: child))
			}
		}
		return result
	}

	private func classList(of element: DOMElement) -> [String] {
		guard let value = element.attributes["class"] as? String else { return [] }
		return value.split(whereSeparator: { $0 == " " }).map(String.init)
	}

	private func rawText(of node: DOMNode) -> String {
		if let text = node as? DOMText { return text.textValue }
		guard let element = node as? DOMElement else { return "" }
		return element.children.map { rawText(of: $0) }.joined()
	}

	private func forEachAnchor(in element: DOMElement, _ body: (DOMElement) -> Void) {
		if element.name.lowercased() == "a" { body(element) }
		for child in element.children {
			if let childElement = child as? DOMElement { forEachAnchor(in: childElement, body) }
		}
	}
}
