import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
import CoreFoundation
#endif

/// Resolve a charset label (e.g. "utf-8", "ISO-8859-1", "windows-1252", "cp932")
/// to a `String.Encoding`. Returns `nil` if unknown or not text (e.g. "binary").
///
/// Notes:
/// - Normalizes case/separators/quotes
/// - Fixes common aliases
/// - Uses CoreFoundation's IANA mapping where available
public func stringEncoding(for rawCharset: String) -> String.Encoding? {
	if rawCharset.isEmpty { return nil }

	var label = rawCharset
		.trimmingCharacters(in: .whitespacesAndNewlines)
		.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
		.lowercased()

	label = label.replacingOccurrences(of: "_", with: "-")
	label = label.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
	label = label.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
	if label.hasSuffix("$esc") { label = String(label.dropLast(4)) }

	let aliasToIANA: [String: String] = [
		"utf8": "utf-8",
		"latin1": "iso-8859-1",
		"latin-1": "iso-8859-1",
		"cp1252": "windows-1252",
		"win-1252": "windows-1252",
		"shift-jis": "shift_jis",
		"sjis": "shift_jis",
		"cp932": "shift_jis",
		"_iso-2022-jp": "iso-2022-jp",
	]
	if let mapped = aliasToIANA[label] { label = mapped }

	switch label {
	case "binary", "x-binary":
		return nil
	default:
		break
	}

	#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
	let cfEnc = CFStringConvertIANACharSetNameToEncoding(label as CFString)
	if cfEnc != kCFStringEncodingInvalidId {
		let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
		return String.Encoding(rawValue: nsEnc)
	}
	#endif

	let additional: [String: String.Encoding] = [
		"utf-8": .utf8,
		"us-ascii": .ascii,
		"iso-8859-1": .isoLatin1,
		"iso-8859-2": .isoLatin2,
		"windows-1250": .windowsCP1250,
		"windows-1251": .windowsCP1251,
		"windows-1252": .windowsCP1252,
		"windows-1253": .windowsCP1253,
		"windows-1254": .windowsCP1254,
		"shift_jis": .shiftJIS,
		"euc-jp": .japaneseEUC,
		"iso-2022-jp": .iso2022JP,
	]
	return additional[label]
}
