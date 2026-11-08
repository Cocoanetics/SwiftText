// WebKit exists on macOS, iOS and Mac Catalyst; see WebKitBrowser.swift.
#if os(macOS) || os(iOS)
import Foundation

extension WebKitBrowser {
	/// The print-time JavaScript that keeps an over-wide table on the page: it
	/// defines `fitTable(table)` and `withPrintStyles(body)` for the table
	/// preparation script to call before it splits tables into page fragments.
	/// Backslashes are doubled for the Swift literal.
	static let tableFittingScript = """
	// Automatic table layout never makes a column narrower than its longest
	// word, so a table whose words alone are too wide runs off the page and
	// WebKit then scales the whole document down. Like the swift engine,
	// keep the narrower columns at that width and cap only the widest ones
	// to an equal share of what is left; words break only in those.
	function fitTable(table) {
		const parent = table.parentElement;
		if (!parent) return;
		const parentStyle = getComputedStyle(parent);
		const contentWidth = parent.clientWidth - parseFloat(parentStyle.paddingLeft)
			- parseFloat(parentStyle.paddingRight);
		// Collapsed outer borders overhang by half their width, hence the slack.
		if (contentWidth <= 2 || table.getBoundingClientRect().width <= contentWidth + 1) return;
		const available = contentWidth - 2;

		const rows = Array.from(table.rows);
		const columnCount = rows.reduce((count, row) =>
			Math.max(count, Array.from(row.cells).reduce((sum, cell) => sum + cell.colSpan, 0)), 0);
		if (columnCount === 0) return;
		// A row with a cell of its own in every column measures the columns'
		// whole-word widths. Without one (spans throughout) fall back to equal
		// columns that may break anywhere, which still keeps the page unscaled.
		const plainRow = rows.find(row => row.cells.length === columnCount
			&& Array.from(row.cells).every(cell => cell.colSpan === 1));
		let widths;
		const capped = new Set();
		if (plainRow) {
			const minimum = Array.from(plainRow.cells).map(cell => cell.getBoundingClientRect().width);
			widths = minimum.slice();
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
		} else {
			widths = new Array(columnCount).fill(available / columnCount);
			for (let column = 0; column < columnCount; column++) capped.add(column);
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
		// Columns are counted by colspan only; a rowspan from an earlier row
		// shifts the cells after it, which at worst misplaces hyphenation.
		for (const row of rows) {
			let column = 0;
			for (const cell of Array.from(row.cells)) {
				const first = column;
				column += cell.colSpan;
				cell.style.setProperty('min-width', '0', 'important');
				let breaks = false;
				for (let spanned = first; spanned < column; spanned++) breaks = breaks || capped.has(spanned);
				if (!breaks) continue;
				cell.style.setProperty('overflow-wrap', 'anywhere', 'important');
				cell.style.setProperty('-webkit-hyphens', 'auto', 'important');
				cell.style.setProperty('hyphens', 'auto', 'important');
			}
		}
	}

	// A media query list as it would match while printing: a print (or all)
	// query keeps its features, queries for other media never match.
	function printMediaText(text) {
		if (!text.trim()) return text;
		return text.split(',').map(query => {
			const match = query.trim().match(/^(only\\s+|not\\s+)?([a-z-]+)(.*)$/i);
			if (!match) return query; // a feature-only query, e.g. "(min-width: 40em)"
			const matchesPrint = ['print', 'all'].includes(match[2].toLowerCase());
			if (/^not/i.test(match[1] || '')) return matchesPrint ? 'not all' : 'all';
			return matchesPrint ? 'all' + match[3] : 'not all';
		}).join(', ');
	}

	// `beforeprint` fires while screen styles still apply. Table widths are
	// decided against the print layout, so every media list is switched to its
	// print reading in place, keeping each rule's position in the cascade, and
	// restored afterwards.
	function withPrintStyles(body) {
		const saved = [];
		function emulate(media) {
			if (!media || !media.mediaText) return;
			saved.push([media, media.mediaText]);
			media.mediaText = printMediaText(media.mediaText);
		}
		function visit(rules) {
			for (const rule of Array.from(rules || [])) {
				emulate(rule.media);
				if (rule.styleSheet) {
					try { visit(rule.styleSheet.cssRules); } catch (_) { /* cross-origin stylesheet */ }
				}
				if (rule.cssRules) visit(rule.cssRules);
			}
		}
		for (const sheet of Array.from(document.styleSheets)) {
			emulate(sheet.media);
			try { visit(sheet.cssRules); } catch (_) { /* cross-origin stylesheet */ }
		}
		try {
			body();
		} finally {
			for (const [media, text] of saved.reverse()) media.mediaText = text;
		}
	}
	"""
}
#endif
