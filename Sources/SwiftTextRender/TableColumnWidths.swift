//  TableColumnWidths.swift
//  SwiftTextRender

import Foundation

/// Fits intrinsic table column widths into the table's available width.
enum TableColumnWidths {
	static func fit(preferred: [Double], minimum: [Double], to availableWidth: Double) -> [Double] {
		let preferredWidth = preferred.reduce(0, +)
		guard preferredWidth > 0 else {
			return [Double](repeating: availableWidth / Double(preferred.count), count: preferred.count)
		}
		guard preferredWidth > availableWidth else { return preferred }

		let minimumWidth = minimum.reduce(0, +)
		guard minimumWidth < availableWidth else {
			guard minimumWidth > 0 else { return preferred }
			return capWidest(minimum, to: availableWidth)
		}

		let flexibility = preferred.indices.map { max(0, preferred[$0] - minimum[$0]) }
		let flexibleWidth = flexibility.reduce(0, +)
		guard flexibleWidth > 0 else { return minimum }
		let scale = (availableWidth - minimumWidth) / flexibleWidth
		return preferred.indices.map { minimum[$0] + flexibility[$0] * scale }
	}

	/// Keeps narrower columns at min-content and shares unavoidable overflow only
	/// among the widest columns, progressively capping them to the same width.
	private static func capWidest(_ minimum: [Double], to availableWidth: Double) -> [Double] {
		var result = minimum
		let columns = minimum.indices.sorted { minimum[$0] < minimum[$1] }
		var remainingWidth = availableWidth
		for (offset, column) in columns.enumerated() {
			let remainingColumns = columns.count - offset
			let cap = remainingWidth / Double(remainingColumns)
			guard minimum[column] < cap else {
				for cappedColumn in columns[offset...] { result[cappedColumn] = cap }
				return result
			}
			remainingWidth -= minimum[column]
		}
		return result
	}
}
