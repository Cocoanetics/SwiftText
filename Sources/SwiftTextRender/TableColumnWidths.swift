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
			let scale = availableWidth / minimumWidth
			return minimum.map { $0 * scale }
		}

		var result = preferred
		var flexible = Set(preferred.indices)
		var fixedWidth = 0.0
		while !flexible.isEmpty {
			let preferredFlexibleWidth = flexible.reduce(0.0) { $0 + preferred[$1] }
			guard preferredFlexibleWidth > 0 else { break }
			let scale = (availableWidth - fixedWidth) / preferredFlexibleWidth
			let belowMinimum = flexible.filter { preferred[$0] * scale < minimum[$0] }
			if belowMinimum.isEmpty {
				for column in flexible { result[column] = preferred[column] * scale }
				break
			}
			for column in belowMinimum {
				result[column] = minimum[column]
				fixedWidth += minimum[column]
				flexible.remove(column)
			}
		}
		return result
	}
}
