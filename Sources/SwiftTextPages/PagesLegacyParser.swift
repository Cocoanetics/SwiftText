import Foundation
#if canImport(FoundationXML)
// On Linux, XMLParser/XMLParserDelegate live in FoundationXML, not Foundation.
import FoundationXML
#endif
import SwiftTextIWA

/// Reads the legacy iWork '09 Pages format, whose content is a single
/// `index.xml` (the APXL schema) rather than `.iwa` objects.
///
/// Body text lives in `<sf:text-storage sf:kind="body">` → `<sf:text-body>` →
/// `<sf:p>` paragraphs, with runs in `<sf:span>`, line breaks as `<sf:br>` and
/// tabs as `<sf:tab>`. Unlike the modern format, paragraph styles do not carry a
/// resolvable font size (it comes from the theme), but their names are the
/// standard set ("Heading 1", "Title", "Body", …), so headings are recovered by
/// matching the style name. `<sf:ghost-text>` is placeholder prompt text and is
/// skipped. Tables (`<sf:tabular-model>`, the same schema Numbers '09 uses) are
/// decoded by the shared ``IWALegacyTableReader`` and appended after the body text.
final class PagesLegacyParser {
	func parseDocument(from data: Data) throws -> PagesDocument {
		let extractor = LegacyExtractor()
		let parser = XMLParser(data: data)
		parser.delegate = extractor
		guard parser.parse() else {
			throw PagesFileError.legacyXMLParsingFailed(parser.parserError)
		}
		var paragraphs = extractor.makeParagraphs()
		// The body XML is known to parse here, so table extraction won't fail; tables are
		// best-effort either way. Each is cropped to its used range and appended as a
		// table-bearing paragraph (legacy in-flow position isn't tracked).
		let tables = ((try? IWALegacyTableReader.tables(fromIndexXML: data)) ?? []).compactMap { $0.trimmedToUsedRange() }
		for table in tables {
			let alignments = table.columnAlignments.map { align -> PagesDocument.Paragraph.Table.ColumnAlignment in
				switch align {
				case .left: return .left
				case .center: return .center
				case .right: return .right
				}
			}
			paragraphs.append(PagesDocument.Paragraph(
				text: "",
				tables: [PagesDocument.Paragraph.Table(cells: table.cells, columnAlignments: alignments)]
			))
		}
		return PagesDocument(paragraphs: paragraphs)
	}
}

private final class LegacyExtractor: NSObject, XMLParserDelegate {
	/// A body paragraph captured during parsing, resolved to a heading level once
	/// the full stylesheet is known.
	private struct RawParagraph {
		var text: String
		var styleRef: String?
	}

	/// Style definitions keyed by both `sfa:ID` and `sf:ident`, each carrying its
	/// display name and parent identifier for the inheritance cascade.
	private struct StyleRecord {
		let name: String?
		let parentIdent: String?
	}

	private var styles: [String: StyleRecord] = [:]
	private var paragraphs: [RawParagraph] = []

	/// Kinds of the currently open `<sf:text-storage>` elements (innermost last).
	private var storageKindStack: [String] = []
	private var isInBodyStorage: Bool { storageKindStack.contains("body") }

	private var currentParagraph: RawParagraph?
	private var ghostTextDepth = 0

	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
		switch localName(elementName) {
		case "text-storage":
			storageKindStack.append(attribute(attributeDict, "kind") ?? "")
		case "paragraphstyle":
			recordStyle(attributeDict)
		case "p":
			guard isInBodyStorage else { break }
			currentParagraph = RawParagraph(text: "", styleRef: attribute(attributeDict, "style"))
		case "ghost-text":
			if currentParagraph != nil { ghostTextDepth += 1 }
		case "br", "lnbr", "crbr", "pgbr", "line-break":
			appendToParagraph("\n")
		case "tab":
			appendToParagraph("\t")
		default:
			break
		}
	}

	func parser(_ parser: XMLParser, foundCharacters string: String) {
		guard currentParagraph != nil, ghostTextDepth == 0 else { return }
		appendToParagraph(string)
	}

	func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
		switch localName(elementName) {
		case "text-storage":
			if !storageKindStack.isEmpty { storageKindStack.removeLast() }
		case "p":
			if let paragraph = currentParagraph {
				paragraphs.append(paragraph)
				currentParagraph = nil
			}
		case "ghost-text":
			if ghostTextDepth > 0 { ghostTextDepth -= 1 }
		default:
			break
		}
	}

	/// Resolves each captured paragraph's style name and turns it into a
	/// `PagesDocument.Paragraph` with an explicit heading level where applicable.
	func makeParagraphs() -> [PagesDocument.Paragraph] {
		paragraphs.map { raw in
			let level = PagesLegacyHeading.level(forStyleName: resolvedStyleName(raw.styleRef))
			return PagesDocument.Paragraph(text: raw.text, headingLevel: level)
		}
	}

	private func appendToParagraph(_ string: String) {
		guard currentParagraph != nil, ghostTextDepth == 0 else { return }
		currentParagraph?.text += string
	}

	private func recordStyle(_ attributes: [String: String]) {
		let record = StyleRecord(name: attribute(attributes, "name"), parentIdent: attribute(attributes, "parent-ident"))
		// A style is referenced from paragraphs by either form of identifier.
		if let id = attribute(attributes, "ID") { styles[id] = record }
		if let ident = attribute(attributes, "ident") { styles[ident] = record }
	}

	/// Follows the parent cascade until a named style is found.
	private func resolvedStyleName(_ reference: String?, depth: Int = 0) -> String? {
		guard depth < 16, let reference, let record = styles[reference] else { return nil }
		if let name = record.name { return name }
		return resolvedStyleName(record.parentIdent, depth: depth + 1)
	}

	private func attribute(_ attributes: [String: String], _ localName: String) -> String? {
		for (key, value) in attributes where self.localName(key) == localName {
			return value
		}
		return nil
	}

	private func localName(_ qualified: String) -> String {
		guard let colon = qualified.firstIndex(of: ":") else { return qualified }
		return String(qualified[qualified.index(after: colon)...])
	}
}

/// Maps legacy paragraph-style names to heading levels.
///
/// The legacy format has no resolvable per-style font size, so headings are
/// recognized by name. Apple's built-in style names are localized, so the most
/// common forms in several languages are matched; an embedded digit selects the
/// level ("Heading 3" → 3). Returns `nil` for body styles.
enum PagesLegacyHeading {
	static func level(forStyleName name: String?) -> Int? {
		guard let name else { return nil }
		let lowered = name.lowercased()
		if ["subtitle", "untertitel", "sous-titre"].contains(where: lowered.contains) {
			return 2
		}
		if ["title", "titel", "titre", "título", "titolo"].contains(where: lowered.contains) {
			return 1
		}
		let headingWords = ["heading", "überschrift", "ueberschrift", "encabezado", "rubrik", "titre"]
		if headingWords.contains(where: lowered.contains) {
			if let digit = lowered.first(where: { $0.isNumber }), let level = Int(String(digit)) {
				return min(max(level, 1), 6)
			}
			return 2
		}
		return nil
	}
}
