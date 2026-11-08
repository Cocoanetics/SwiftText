//
//  EpubNavLabels.swift
//  SwiftTextEPUB
//
//  The fixed strings of the generated navigation document (page title and
//  landmark labels), localised by the book's `dc:language`. Foundation-free.

/// Navigation-document strings for one language.
public struct EpubNavLabels: Equatable, Sendable {
	public let tableOfContents: String
	public let cover: String
	public let titlePage: String
	public let beginning: String

	public static let english = EpubNavLabels(tableOfContents: "Table of Contents", cover: "Cover", titlePage: "Title Page", beginning: "Beginning")

	private static let table: [String: EpubNavLabels] = [
		"de": EpubNavLabels(tableOfContents: "Inhalt", cover: "Umschlag", titlePage: "Titelseite", beginning: "Anfang"),
		"fr": EpubNavLabels(tableOfContents: "Table des matières", cover: "Couverture", titlePage: "Page de titre", beginning: "Début"),
		"es": EpubNavLabels(tableOfContents: "Índice", cover: "Portada", titlePage: "Página de título", beginning: "Comienzo"),
		"it": EpubNavLabels(tableOfContents: "Indice", cover: "Copertina", titlePage: "Frontespizio", beginning: "Inizio"),
		"nl": EpubNavLabels(tableOfContents: "Inhoudsopgave", cover: "Omslag", titlePage: "Titelpagina", beginning: "Begin"),
		"pt": EpubNavLabels(tableOfContents: "Índice", cover: "Capa", titlePage: "Folha de rosto", beginning: "Início")
	]

	/// Labels for a BCP 47 tag such as `de-AT`; English for unknown languages.
	public static func labels(forLanguage language: String) -> EpubNavLabels {
		let primary = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
		return table[primary] ?? .english
	}
}
