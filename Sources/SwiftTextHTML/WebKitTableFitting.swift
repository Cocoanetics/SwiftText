// WebKit exists on macOS, iOS and Mac Catalyst; see WebKitBrowser.swift.
#if os(macOS) || os(iOS)
import Foundation

extension WebKitBrowser {
	/// The print-time JavaScript that keeps an over-wide table on the page: it
	/// defines `fitTable(table)` and `withPrintStyles(body)` for the table
	/// preparation script to call before it splits tables into page fragments.
	static let tableFittingScript = """
	// Automatic table layout never makes a column narrower than its longest
	// word, so a table whose words alone are too wide runs off the page and
	// WebKit then scales the whole document down. Like the swift engine,
	// keep the narrower columns at that width and cap only the widest ones
	// to an equal share of what is left; words break only in those.
	function fitTable(table) {
		const parent = table.parentElement;
		const firstRow = table.rows[0];
		if (!parent || !firstRow || Array.from(firstRow.cells).some(cell => cell.colSpan > 1)) return;
		const parentStyle = getComputedStyle(parent);
		const contentWidth = parent.clientWidth - parseFloat(parentStyle.paddingLeft)
			- parseFloat(parentStyle.paddingRight);
		// Collapsed outer borders overhang by half their width, hence the slack.
		if (contentWidth <= 2 || table.getBoundingClientRect().width <= contentWidth + 1) return;
		const available = contentWidth - 2;

		const minimum = Array.from(firstRow.cells).map(cell => cell.getBoundingClientRect().width);
		const widths = minimum.slice();
		const capped = new Set();
		const columns = minimum.map((_, index) => index).sort((a, b) => minimum[a] - minimum[b]);
		let remaining = available;
		for (const [offset, column] of columns.entries()) {
			const cap = remaining / (columns.length - offset);
			if (minimum[column] >= cap) {
				for (const column of columns.slice(offset)) {
					widths[column] = cap;
					capped.add(column);
				}
				break;
			}
			remaining -= minimum[column];
		}

		for (const child of Array.from(table.children)) {
			if (child.tagName === 'COLGROUP') child.remove();
		}
		const colgroup = document.createElement('colgroup');
		for (const width of widths) {
			const col = document.createElement('col');
			col.style.width = width + 'px';
			colgroup.appendChild(col);
		}
		table.insertBefore(colgroup, table.tHead || table.tBodies[0] || table.firstChild);
		table.style.setProperty('table-layout', 'fixed', 'important');
		table.style.setProperty('width', available + 'px', 'important');
		for (const cell of Array.from(table.querySelectorAll('th, td'))) {
			cell.style.setProperty('min-width', '0', 'important');
			if (!capped.has(cell.cellIndex)) continue;
			cell.style.setProperty('overflow-wrap', 'anywhere', 'important');
			cell.style.setProperty('-webkit-hyphens', 'auto', 'important');
			cell.style.setProperty('hyphens', 'auto', 'important');
		}
	}

	// `beforeprint` fires while screen styles still apply. Table widths are
	// decided against the print layout, so lend the print rules out meanwhile.
	function withPrintStyles(body) {
		const rules = [];
		function collect(list) {
			for (const rule of Array.from(list || [])) {
				if (rule.type === CSSRule.MEDIA_RULE && Array.from(rule.media).includes('print')) {
					for (const inner of Array.from(rule.cssRules)) rules.push(inner.cssText);
				}
			}
		}
		for (const sheet of Array.from(document.styleSheets)) {
			try { collect(sheet.cssRules); } catch (_) { /* cross-origin stylesheet */ }
		}
		const style = document.createElement('style');
		style.textContent = rules.join('\\n');
		document.head.appendChild(style);
		try { body(); } finally { style.remove(); }
	}
	"""
}
#endif
