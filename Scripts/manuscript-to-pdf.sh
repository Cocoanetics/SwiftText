#!/usr/bin/env bash
#
# manuscript-to-pdf.sh — render a Markdown manuscript to a print-ready PDF
# using the `swifttext` CLI, with every chapter (an h2 heading) starting on a
# fresh page.
#
# Usage:
#   Scripts/manuscript-to-pdf.sh [INPUT.md] [OUTPUT.pdf]
#
# Defaults to the Shattered Skies manuscript and writes a sibling .pdf.
#
set -euo pipefail

# --- locate the Swift package (this script lives in <package>/Scripts) --------
PKG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Keep SwiftPM build artifacts off the internal disk (see global build policy).
SCRATCH="/Volumes/SSD/SwiftPM/$(basename "$PKG_ROOT")"
[ -d /Volumes/SSD ] || SCRATCH="$PKG_ROOT/.build"

# --- arguments ----------------------------------------------------------------
INPUT="${1:-/Users/oliver/Developer/Canon/Project/manuscript/The-Shattered-Skies.md}"
OUTPUT="${2:-${INPUT%.*}.pdf}"

if [ ! -f "$INPUT" ]; then
	echo "error: manuscript not found: $INPUT" >&2
	exit 1
fi

# --- build the CLI once, then invoke the built binary -------------------------
echo "Building swifttext (release) → $SCRATCH ..." >&2
swift build -c release --scratch-path "$SCRATCH" --product swifttext --package-path "$PKG_ROOT"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --product swifttext --package-path "$PKG_ROOT" --show-bin-path)/swifttext"

# --- render -------------------------------------------------------------------
# --page-break-before h2 forces each chapter (## heading) onto a new page.
echo "Rendering $INPUT → $OUTPUT ..." >&2
"$BIN" render "$INPUT" --output "$OUTPUT" --format pdf --paper a4 --page-break-before h2

echo "Wrote $OUTPUT" >&2
