//
//  RecognitionLanguages.swift
//  SwiftTextOCR
//

import Foundation
#if canImport(Vision)
import Vision
#endif

/// Turns the language hints a caller typed (`de`, `en-US`, `de,en`) into the
/// identifiers Vision expects for `recognitionLanguages`.
public enum RecognitionLanguages {
	/// Splits comma-separated values, trims them and drops empties and repeats,
	/// keeping the order the caller gave: Vision weighs earlier languages higher.
	public static func parse(_ values: [String]) -> [String] {
		var seen = Set<String>()
		var result = [String]()
		for value in values {
			for part in value.split(separator: ",") {
				let code = part.trimmingCharacters(in: .whitespaces)
				if !code.isEmpty, seen.insert(code.lowercased()).inserted {
					result.append(code)
				}
			}
		}
		return result
	}

	/// The requested codes that match no supported language, so a typo can be
	/// reported instead of silently producing no text.
	public static func unsupported(_ requested: [String], supported: [String]) -> [String] {
		// With no supported list to check against (no recogniser on this host), nothing can be judged.
		guard !supported.isEmpty else { return [] }
		return parse(requested).filter { code in
			let resolved = resolve([code], supported: supported)
			return !supported.contains { $0.lowercased() == resolved[0].lowercased() }
		}
	}

	/// Maps each requested code to a language the recogniser supports. A bare
	/// code such as `de` resolves to the first supported identifier for that
	/// language (`de-DE`); a code with no match passes through unchanged so
	/// Vision can reject it itself.
	public static func resolve(_ requested: [String], supported: [String]) -> [String] {
		var result = [String]()
		for code in parse(requested) {
			let lowered = code.lowercased()
			let match = supported.first { $0.lowercased() == lowered }
				?? supported.first { $0.lowercased().split(separator: "-").first.map(String.init) == lowered }
			let resolved = match ?? code
			if !result.contains(resolved) {
				result.append(resolved)
			}
		}
		return result
	}
}

#if canImport(Vision)
public extension RecognitionLanguages {
	/// The language identifiers Vision's text recogniser supports.
	@available(iOS 13.0, tvOS 13.0, macOS 10.15, visionOS 1.0, *)
	static var supported: [String] {
		(try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
	}
}

@available(iOS 13.0, tvOS 13.0, macOS 10.15, visionOS 1.0, *)
func makeTextRecognitionRequest(languages: [String]) -> VNRecognizeTextRequest {
	let request = VNRecognizeTextRequest()
	request.recognitionLevel = .accurate

	let requested = RecognitionLanguages.parse(languages)
	if !requested.isEmpty {
		let supported = (try? request.supportedRecognitionLanguages()) ?? []
		request.recognitionLanguages = RecognitionLanguages.resolve(requested, supported: supported)
	}
	return request
}

@available(iOS 26.0, tvOS 26.0, macOS 26.0, visionOS 26.0, *)
func applyRecognitionLanguages(_ languages: [String], to request: inout RecognizeDocumentsRequest) {
	let requested = RecognitionLanguages.parse(languages)
	guard !requested.isEmpty else { return }
	request.textRecognitionOptions.recognitionLanguages = requested.map { Locale.Language(identifier: $0) }
}
#endif
