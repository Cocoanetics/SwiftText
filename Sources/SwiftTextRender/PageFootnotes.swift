//  PageFootnotes.swift
//  SwiftTextRender
//
//  Notes at the foot of the page (`RenderOptions.pageFootnotes`). The note
//  definitions are lifted out of the flow and laid out on their own; pagination
//  then reserves, for each candidate page break, the room the notes of the
//  lines above the break need (plus a separator) and only breaks where the
//  lines and their notes fit together. A line whose note does not fit moves to
//  the next page with it, and a note longer than a page continues in the
//  foot area of the next one.

import Foundation
import SwiftTextCSS

/// A note definition taken out of the flow.
struct PageFootnote {
	let id: String
	let box: BlockBox
	/// The margin-box height of the note laid out at the column width.
	var height = 0.0
	/// The y offsets inside the note where it may be split: line and block edges.
	var breaks: [Double] = []
	/// The notes this note's text refers to; they stand on the page of its reference.
	var nested: [String] = []
}

/// The part of a note set on one page: the rows `from ..< to` of the note.
struct FootnoteChunk {
	let note: Int
	let from: Double
	let to: Double
	var height: Double { to - from }
}

/// Where a note is referenced: the column y of the top of the line holding the reference.
struct FootnoteReference {
	let y: Double
	let note: Int
}

struct FootnoteSet {
	/// The class of the element carrying a note definition.
	static let definitionClass = "footnote-definition"
	/// Room above the first note, holding the rule.
	static let separatorHeight = 14.0
	/// Where the rule sits inside the separator, from its top.
	static let ruleOffset = 6.0

	/// Built-in styling of the notes at the foot of the page: smaller, and tighter than in the flow.
	static let css = """
	.footnote-definition { font-size: 0.85em; margin: 0.3em 0; }
	.footnote-definition p { margin: 0.2em 0; }
	"""

	var notes: [PageFootnote]
	var references: [FootnoteReference] = []
	/// Links to a note read `#fn-…`, or that against the document's base URL once the DOM has resolved them.
	var baseURL: URL?

	var isEmpty: Bool { notes.isEmpty }

	// MARK: - Extraction

	/// Remove the definitions that something references from the box tree. A
	/// definition nothing references stays where it is.
	static func extract(from root: BlockBox, baseURL: URL?) -> FootnoteSet {
		func noteIDs(in box: Box) -> [String] {
			var ids: [String] = []
			func scan(_ box: Box) {
				if let inline = box as? InlineBox {
					if inline.element?.localName == "a", let href = inline.element?.attributeValue("href"),
					   let id = noteID(inHref: href, baseURL: baseURL) {
						ids.append(id)
					}
					inline.children.forEach(scan)
				} else if let block = box as? BlockBox {
					block.children.forEach(scan)
				}
			}
			scan(box)
			return ids
		}
		let referenced = Set(noteIDs(in: root))
		var notes: [PageFootnote] = []
		func lift(_ block: BlockBox) {
			var kept: [Box] = []
			for child in block.children {
				if let candidate = child as? BlockBox, let element = candidate.element,
				   let id = element.attributeValue("id"), referenced.contains(id),
				   (element.attributeValue("class") ?? "").split(separator: " ").contains(Substring(definitionClass)),
				   !notes.contains(where: { $0.id == id }) {
					notes.append(PageFootnote(id: id, box: candidate))
				} else {
					if let candidate = child as? BlockBox { lift(candidate) }
					kept.append(child)
				}
			}
			block.children = kept
		}
		lift(root)
		for index in notes.indices { notes[index].nested = noteIDs(in: notes[index].box) }
		return FootnoteSet(notes: notes, baseURL: baseURL)
	}

	/// The id of the note a link points at, if it is a link to one.
	static func noteID(inHref href: String, baseURL: URL?) -> String? {
		var fragment = Substring(href)
		if !fragment.hasPrefix("#") {
			guard let base = baseURL?.absoluteString, fragment.hasPrefix(base) else { return nil }
			fragment = fragment.dropFirst(base.count)
		}
		return fragment.hasPrefix("#fn-") ? String(fragment.dropFirst()) : nil
	}

	// MARK: - Layout

	/// Lay the notes out at the column width and find where each can be split.
	mutating func layoutNotes(engine: LayoutEngine, contentWidth: Double, originX: Double) {
		for index in notes.indices {
			let box = notes[index].box
			notes[index].height = engine.layout(root: box, contentWidth: contentWidth, originX: originX, originY: 0)
			var breaks: Set<Double> = []
			func collect(_ box: Box) {
				guard let block = box as? BlockBox else { return }
				breaks.insert(block.y)
				breaks.insert(block.y + block.height)
				for line in block.lines {
					breaks.insert(line.y)
					breaks.insert(line.y + line.height)
				}
				block.children.forEach(collect)
			}
			collect(box)
			notes[index].breaks = breaks.sorted()
		}
	}

	/// Find the line each note is referenced from in the laid-out column.
	mutating func locateReferences(in root: BlockBox) {
		var indexByID: [String: Int] = [:]
		for (index, note) in notes.enumerated() { indexByID[note.id] = index }
		var found: [FootnoteReference] = []
		var seen = Set<Int>()
		func walk(_ block: BlockBox) {
			for line in block.lines {
				for fragment in line.fragments {
					guard let href = fragment.href, let id = Self.noteID(inHref: href, baseURL: baseURL), let note = indexByID[id],
					      seen.insert(note).inserted else { continue }
					found.append(FootnoteReference(y: line.y, note: note))
				}
			}
			for case let child as BlockBox in block.children { walk(child) }
		}
		walk(root)
		// A note referred to from another note's text goes where that note goes; a
		// note nothing in the text reaches follows the last reference rather than vanishing.
		var ordered: [FootnoteReference] = []
		var placed = Set<Int>()
		func place(_ note: Int, at y: Double) {
			guard placed.insert(note).inserted else { return }
			ordered.append(FootnoteReference(y: y, note: note))
			for id in notes[note].nested { indexByID[id].map { place($0, at: y) } }
		}
		for reference in found.sorted(by: { $0.y < $1.y }) { place(reference.note, at: reference.y) }
		let lastY = ordered.last?.y ?? 0
		for index in notes.indices { place(index, at: lastY) }
		references = ordered
	}

	// MARK: - Distribution

	/// The notes a page needs when it shows the column rows `top ..< bottom`:
	/// what spilled over from the page before, then the notes of the lines on this page.
	func entries(carry: [FootnoteChunk], top: Double, bottom: Double, epsilon: Double) -> [FootnoteChunk] {
		var result = carry
		for reference in references where reference.y >= top - epsilon && reference.y < bottom - epsilon {
			result.append(FootnoteChunk(note: reference.note, from: 0, to: notes[reference.note].height))
		}
		return result
	}

	/// The height of the foot area holding `entries`; nothing when there are none.
	static func areaHeight(of entries: [FootnoteChunk]) -> Double {
		entries.isEmpty ? 0 : separatorHeight + entries.reduce(0) { $0 + $1.height }
	}

	/// Set `entries` into `room` points. What does not fit continues on the next
	/// page: the last note that fits is split at its last line that does, and the
	/// notes after it wait whole. `force` allows cutting through a line, for a
	/// page with nothing but notes on it.
	func fill(_ entries: [FootnoteChunk], room: Double, force: Bool, epsilon: Double) -> (placed: [FootnoteChunk], carry: [FootnoteChunk]) {
		var remaining = room
		var placed: [FootnoteChunk] = []
		for (index, entry) in entries.enumerated() {
			if entry.height <= remaining + epsilon {
				placed.append(entry)
				remaining -= entry.height
				continue
			}
			var rest = Array(entries[(index + 1)...])
			let limit = entry.from + remaining
			var cut = notes[entry.note].breaks.last { $0 > entry.from + epsilon && $0 <= limit + epsilon && $0 < entry.to - epsilon }
			// A page of nothing but notes has to take something, even through a line.
			if cut == nil, force, placed.isEmpty { cut = min(max(limit, entry.from + 1), entry.to) }
			if let cut, cut >= entry.to - epsilon {
				placed.append(entry)
				return (placed, rest)
			}
			if let cut {
				placed.append(FootnoteChunk(note: entry.note, from: entry.from, to: cut))
				rest.insert(FootnoteChunk(note: entry.note, from: cut, to: entry.to), at: 0)
			} else {
				rest.insert(entry, at: 0)
			}
			return (placed, rest)
		}
		return (placed, [])
	}
}
