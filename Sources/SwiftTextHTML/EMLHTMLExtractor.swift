import Foundation

// MARK: - EML → HTML

/// Extracts the HTML body from an EML (MIME) email.
///
/// Handles `multipart/*` with nested parts and base64, quoted-printable and
/// 7bit/8bit transfer encodings. Bodies are decoded to bytes first and then to
/// a string using the part's declared `charset` (falling back to UTF-8, then
/// ISO-8859-1).
public func extractHTMLFromEML(_ data: Data) -> String? {
	// ISO-8859-1 maps every byte to exactly one scalar, so this is lossless and
	// lets the line-based parsing below run on a String.
	guard let raw = String(data: data, encoding: .isoLatin1) else { return nil }
	return extractHTMLFromEML(latin1: raw)
}

private func extractHTMLFromEML(latin1 content: String) -> String? {
	let text = content
		.replacingOccurrences(of: "\r\n", with: "\n")
		.replacingOccurrences(of: "\r", with: "\n")

	let (topHeaders, topBody) = mimeHeadersAndBody(text)
	let contentType = topHeaders["content-type"] ?? ""

	if contentType.lowercased().contains("multipart"),
	   let boundary = mimeParameter("boundary", from: contentType) {
		let parts = mimeParts(of: text, boundary: boundary)
		// Direct text/html part
		for part in parts {
			let (h, body) = mimeHeadersAndBody(part)
			let ct = h["content-type"] ?? ""
			if ct.lowercased().contains("text/html") {
				return decodeMIMEBody(body, headers: h)
			}
		}
		// Nested multipart
		for part in parts {
			let (h, _) = mimeHeadersAndBody(part)
			let ct = h["content-type"] ?? ""
			if ct.lowercased().contains("multipart"),
			   let nested = extractHTMLFromEML(latin1: part) {
				return nested
			}
		}
	} else if contentType.lowercased().contains("text/html") {
		return decodeMIMEBody(topBody, headers: topHeaders)
	}

	// Fallback: scan for <html
	if let range = text.range(of: "<html", options: .caseInsensitive) {
		return decodeText(latin1Bytes(String(text[range.lowerBound...])),
						  charset: mimeParameter("charset", from: contentType))
	}
	return nil
}

// MARK: - MIME helpers

/// Parses MIME headers from the top of `text`.
/// Returns a dictionary of lowercased header names → values, and the body string.
private func mimeHeadersAndBody(_ text: String) -> ([String: String], String) {
	var headers: [String: String] = [:]
	let lines = text.components(separatedBy: "\n")
	var bodyStart = lines.endIndex
	var lastKey: String?

	for (idx, line) in lines.enumerated() {
		if line.trimmingCharacters(in: .whitespaces).isEmpty {
			bodyStart = idx + 1
			break
		}
		// Folded header continuation
		if line.hasPrefix("\t") || line.hasPrefix(" "), let key = lastKey {
			headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
			continue
		}
		if let colonIdx = line.firstIndex(of: ":") {
			let key   = String(line[..<colonIdx]).lowercased().trimmingCharacters(in: .whitespaces)
			let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
			headers[key] = value
			lastKey = key
		}
	}

	let body: String
	if bodyStart < lines.endIndex {
		body = lines[bodyStart...].joined(separator: "\n")
	} else {
		body = ""
	}
	return (headers, body)
}

/// Extracts a parameter value (e.g. `boundary`, `charset`) from a Content-Type
/// header. Parameter names are case-insensitive; values may be quoted.
private func mimeParameter(_ name: String, from contentType: String) -> String? {
	for part in contentType.components(separatedBy: ";") {
		guard let eq = part.firstIndex(of: "=") else { continue }
		let key = part[..<eq].trimmingCharacters(in: .whitespaces)
		guard key.caseInsensitiveCompare(name) == .orderedSame else { continue }
		var v = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
		if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
		return v
	}
	return nil
}

/// Splits a MIME body into parts using the given boundary string.
private func mimeParts(of text: String, boundary: String) -> [String] {
	let delim = "--" + boundary
	let end   = "--" + boundary + "--"
	var parts: [String] = []
	var current: [String] = []
	var inside = false

	for line in text.components(separatedBy: "\n") {
		let s = line.trimmingCharacters(in: .whitespaces)
		if s == end { break }
		if s == delim {
			if inside { parts.append(current.joined(separator: "\n")) }
			current = []; inside = true; continue
		}
		if inside { current.append(line) }
	}
	if inside, !current.isEmpty { parts.append(current.joined(separator: "\n")) }
	return parts
}

/// Decodes a part body according to its Content-Transfer-Encoding and charset.
private func decodeMIMEBody(_ body: String, headers: [String: String]) -> String {
	let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
	let charset = mimeParameter("charset", from: headers["content-type"] ?? "")
	let bodyBytes = latin1Bytes(body)

	switch encoding {
	case "base64":
		let compact = body.components(separatedBy: .whitespacesAndNewlines).joined()
		if let data = Data(base64Encoded: compact) {
			return decodeText(data, charset: charset)
		}
		return decodeText(bodyBytes, charset: charset)
	case "quoted-printable":
		return decodeText(decodeQuotedPrintable(bodyBytes), charset: charset)
	default:
		return decodeText(bodyBytes, charset: charset)
	}
}

/// The bytes of a string produced by the ISO-8859-1 pass (one byte per scalar).
private func latin1Bytes(_ text: String) -> Data {
	Data(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
}

/// Decodes bytes with the declared charset; falls back to UTF-8, then ISO-8859-1.
private func decodeText(_ data: Data, charset: String?) -> String {
	if let charset, let enc = stringEncoding(for: charset),
	   let s = String(data: data, encoding: enc) {
		return s
	}
	return String(data: data, encoding: .utf8)
		?? String(data: data, encoding: .isoLatin1)
		?? ""
}

private func hexValue(_ byte: UInt8) -> UInt8? {
	switch byte {
	case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
	case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
	case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
	default: return nil
	}
}

/// Quoted-printable decoder producing raw bytes.
/// Soft line breaks are joined; `=` not followed by two hex digits stays literal.
private func decodeQuotedPrintable(_ data: Data) -> Data {
	let bytes = [UInt8](data)
	var result = Data()
	result.reserveCapacity(bytes.count)
	let equals = UInt8(ascii: "="), newline = UInt8(ascii: "\n")
	var i = 0
	while i < bytes.count {
		let b = bytes[i]
		if b == equals {
			if i + 1 < bytes.count, bytes[i + 1] == newline {
				i += 2; continue
			}
			if i + 2 < bytes.count,
			   let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
				result.append(hi << 4 | lo)
				i += 3; continue
			}
		}
		result.append(b)
		i += 1
	}
	return result
}
