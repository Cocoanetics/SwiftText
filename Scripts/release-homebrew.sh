#!/bin/bash
# Points the Homebrew formula (cocoanetics/tap/swifttext) at a release tag's
# source tarball. MissionControl's release recipe runs it after tagging and
# creating the GitHub release, with MC_RELEASE_VERSION and MC_RELEASE_TAG set.
# Needs only a signed-in `gh` (GitHub API, no clone). Safe to re-run.
#
#   DRY_RUN=1 Scripts/release-homebrew.sh 2.10.0   # preview, writes nothing
#
# The recipe (`mc repo set Cocoanetics/SwiftText --release-recipe @recipe.json`):
#   {"version": {"kind": "tag"}, "production": {"tag": "{version}", "steps": [
#     {"kind": "command", "run": ["Scripts/release-homebrew.sh"], "title": "Update Homebrew tap"}]}}

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

VERSION="${MC_RELEASE_VERSION:-${1:-}}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <version>   (or set MC_RELEASE_VERSION)" >&2
    exit 64
fi
TAG="${MC_RELEASE_TAG:-$VERSION}"
DRY_RUN="${DRY_RUN:-0}"

TAP="Cocoanetics/homebrew-tap"
FORMULA="Formula/swifttext.rb"
URL="https://github.com/Cocoanetics/SwiftText/archive/refs/tags/$TAG.tar.gz"

# Fetch the formula blob at a specific commit so the edit and expectedHeadOid
# refer to the same revision (concurrent tap updates then reject the mutation).
fetch_formula() { gh api "repos/$TAP/contents/$FORMULA?ref=$1" --jq .content | base64 -d; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

head=$(gh api "repos/$TAP/branches/main" --jq .commit.sha)
fetch_formula "$head" >"$work/formula.rb"
cp "$work/formula.rb" "$work/formula.orig.rb"
if grep -qF "url \"$URL\"" "$work/formula.rb"; then
    echo "$FORMULA already points at $TAG"
    exit 0
fi

curl -fsSL --retry 5 --retry-delay 5 -o "$work/source.tar.gz" "$URL"
SHA=$(shasum -a 256 "$work/source.tar.gz" | cut -d' ' -f1)

sed -E -i '' \
    -e "s|^(  url )\".*\"$|\1\"$URL\"|" \
    -e "s|^(  sha256 )\"[0-9a-f]{64}\"$|\1\"$SHA\"|" \
    "$work/formula.rb"
grep -qF "url \"$URL\"" "$work/formula.rb" && grep -qF "sha256 \"$SHA\"" "$work/formula.rb" || {
    echo "Could not update the url/sha256 lines in $FORMULA" >&2
    exit 1
}
diff -u "$work/formula.orig.rb" "$work/formula.rb" || true

if [[ "$DRY_RUN" == 1 ]]; then
    echo "[dry run] would commit 'swifttext $VERSION' to $TAP@main (head $head)"
    exit 0
fi

# Build the GraphQL body with gh only (no standalone jq). Values are version /
# hex / base64, so embedding them in JSON is safe for this script's inputs.
contents_b64=$(base64 -i "$work/formula.rb" | tr -d '\n')
cat >"$work/payload.json" <<EOF
{
  "query": "mutation(\$input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: \$input) { commit { url } } }",
  "variables": {
    "input": {
      "branch": {
        "repositoryNameWithOwner": "$TAP",
        "branchName": "main"
      },
      "expectedHeadOid": "$head",
      "message": {
        "headline": "swifttext $VERSION"
      },
      "fileChanges": {
        "additions": [
          {
            "path": "$FORMULA",
            "contents": "$contents_b64"
          }
        ]
      }
    }
  }
}
EOF
gh api graphql --input "$work/payload.json" --jq .data.createCommitOnBranch.commit.url
echo "Updated $FORMULA to $TAG ($SHA)"
