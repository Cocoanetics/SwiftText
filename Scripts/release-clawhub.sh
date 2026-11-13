#!/bin/bash
# Publishes the agent skill (Skills/swifttext, from the tagged tree) to ClawHub
# as `swifttext` at SwiftText's version, with the release notes as changelog.
# MissionControl's release recipe runs it after tagging, with MC_RELEASE_VERSION,
# MC_RELEASE_TAG and MC_RELEASE_NOTES_FILE set. Needs a signed-in `clawhub`
# (`clawhub login`). Safe to re-run: a version already on ClawHub is skipped.
#
#   DRY_RUN=1 Scripts/release-clawhub.sh 2.10.0   # clawhub --dry-run, publishes nothing

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

VERSION="${MC_RELEASE_VERSION:-${1:-}}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <version>   (or set MC_RELEASE_VERSION)" >&2
    exit 64
fi
TAG="${MC_RELEASE_TAG:-$VERSION}"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)/Skills/swifttext"

# A version still in ClawHub's security review isn't visible yet; a re-run
# during review then fails on the duplicate instead of publishing twice.
if clawhub --no-input inspect swifttext --version "$VERSION" --json >/dev/null 2>&1; then
    echo "ClawHub already has swifttext $VERSION"
    exit 0
fi

CHANGELOG="SwiftText $TAG: https://github.com/Cocoanetics/SwiftText/releases/tag/$TAG"
if [[ -s "${MC_RELEASE_NOTES_FILE:-}" ]]; then
    CHANGELOG="$(cat "$MC_RELEASE_NOTES_FILE")"
fi

PUBLISH_ARGS=(--no-input publish "$SKILL_DIR" --slug swifttext --name SwiftText --version "$VERSION" \
    --changelog "$CHANGELOG")
if [[ "${DRY_RUN:-0}" == 1 ]]; then
    PUBLISH_ARGS+=(--dry-run)
fi
clawhub "${PUBLISH_ARGS[@]}"
