#!/usr/bin/env bash
# Runs CI's checks locally on a branch merged into the current origin/main.
# Use it when GitHub Actions cannot run (ADR 0007). It checks what main would
# look like after the merge, in a throwaway worktree, so the caller's checkout
# is left alone.
# Usage: Tools/local-gate.sh <branch>   ("main" gates origin/main itself)
set -uo pipefail

branch="${1:?usage: Tools/local-gate.sh <branch>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/starling-gate.XXXXXX")"

cleanup() { git -C "$root" worktree remove --force "$work" 2>/dev/null; rm -rf "$work"; }
fail() { echo "GATE FAIL ($branch): $1"; cleanup; exit 1; }

git -C "$root" fetch -q origin || fail "fetch"
git -C "$root" rev-parse -q --verify "origin/$branch" >/dev/null || fail "no branch origin/$branch"
git -C "$root" worktree add -q --detach "$work" origin/main || fail "worktree"
echo "main $(git -C "$work" rev-parse --short HEAD)"
if [ "$branch" != main ]; then
  echo "branch $(git -C "$root" rev-parse --short "origin/$branch")"
  git -C "$work" merge -q --no-edit "origin/$branch" || fail "merge conflict with main"
fi

# The same jobs and steps as .github/workflows/ci.yml, in the same order.
echo "== packages"
"$work/Tools/test-all.sh" || fail "package tests"

echo "== app"
(cd "$work" && xcodegen generate --spec App/project.yml >/dev/null) || fail "xcodegen"
xcodebuild build -quiet \
  -project "$work/App/Starling.xcodeproj" -scheme Starling \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$work/.build-app" \
  CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES || fail "app build"
"$work/Tools/check-release-no-fakes.sh" "$work/.build-release" || fail "Release build or no-fakes check"

cleanup
echo "GATE PASS ($branch)"
