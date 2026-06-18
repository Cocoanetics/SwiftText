import Foundation

/// A minimal, read-only model of an Apple Numbers spreadsheet: an ordered list of
/// sheets, each carrying the tables found on it as decoded `TSTTable` grids of frozen
/// (cached) values. There is no formula engine — every cell reads as the static value
/// Numbers last computed and stored, which is what `wiki`-style consumers and LLM
/// agents want when they ask "what does this spreadsheet say right now."
public struct NumbersDocument: Sendable, Codable {
	public struct Sheet: Sendable, Codable {
		/// The sheet's tab name, when the document records one.
		public var name: String?
		public var tables: [TSTTable]

		public init(name: String?, tables: [TSTTable]) {
			self.name = name
			self.tables = tables
		}
	}

	public var sheets: [Sheet]

	public init(sheets: [Sheet]) {
		self.sheets = sheets
	}

	/// Every table in document order, flattened across sheets.
	public var allTables: [TSTTable] { sheets.flatMap(\.tables) }
}
