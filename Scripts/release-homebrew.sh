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

fetch_formula() { gh api "repos/$TAP/contents/$FORMULA?ref=main" --jq .content | base64 -d; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fetch_formula >"$work/formula.rb"
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
diff -u <(fetch_formula) "$work/formula.rb" || true

head=$(gh api "repos/$TAP/branches/main" --jq .commit.sha)
if [[ "$DRY_RUN" == 1 ]]; then
    echo "[dry run] would commit 'swifttext $VERSION' to $TAP@main (head $head)"
    exit 0
fi
jq -n --arg repo "$TAP" --arg head "$head" --arg message "swifttext $VERSION" \
    --arg path "$FORMULA" --arg contents "$(base64 -i "$work/formula.rb")" '{
        query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { url } } }",
        variables: { input: {
            branch: { repositoryNameWithOwner: $repo, branchName: "main" },
            expectedHeadOid: $head,
            message: { headline: $message },
            fileChanges: { additions: [{ path: $path, contents: $contents }] }
        } }
    }' | gh api graphql --input - --jq .data.createCommitOnBranch.commit.url
echo "Updated $FORMULA to $TAG ($SHA)"
