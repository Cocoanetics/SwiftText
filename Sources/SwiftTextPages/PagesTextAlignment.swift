import SwiftTextIWA
import SwiftTextMarkdown

extension MarkdownTextAlignment.Alignment {
	/// The `TSWP.ParagraphStylePropertiesArchive.alignment` (#1) value Pages writes:
	/// left = 0, right = 1, center = 2, justified = 3.
	var pagesValue: UInt64 {
		switch self {
		case .left: return 0
		case .right: return 1
		case .center: return 2
		case .justify: return 3
		}
	}
}

extension PagesBodySerializer {
	/// Returns a paragraph-style payload with its `alignment` (para_properties #1) set
	/// to `value` (see ``MarkdownTextAlignment/Alignment/pagesValue``). Other fields are
	/// preserved.
	static func settingAlignment(in stylePayload: [UInt8], _ value: UInt64) -> [UInt8] {
		let style = ProtobufMessage(stylePayload)
		var writer = ProtobufWriter()
		var wrote = false
		for field in style.fields {
			guard field.number == 12, case .lengthDelimited(let paraProperties) = field.value else { writer.append(field); continue }
			var inner = ProtobufWriter()
			inner.varintField(1, value)
			for property in ProtobufMessage(paraProperties).fields where property.number != 1 {
				inner.append(property)
			}
			writer.bytesField(12, inner.bytes)
			wrote = true
		}
		if !wrote {
			var inner = ProtobufWriter()
			inner.varintField(1, value)
			writer.bytesField(12, inner.bytes)
		}
		return writer.bytes
	}
}
