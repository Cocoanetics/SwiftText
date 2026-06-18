#!/usr/bin/env bash
# Point this clone's git hooks at the shared Scripts/hooks dir.
# Run once after cloning.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath Scripts/hooks
echo "core.hooksPath -> Scripts/hooks"
