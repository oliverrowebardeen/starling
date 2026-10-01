#!/usr/bin/env bash
# Fails if a Release build contains the Debug-only Developer section or a
# test-build notice (ADR 0015 decision 5, requested by lane P15-A). Reuses
# the Release build that check-release-no-fakes.sh makes, so run that first.
# Usage: Tools/check-release-no-debug.sh [derived-data-path]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
derived="${1:-$root/.build/app-release}"
binary="$derived/Build/Products/Release-iphonesimulator/Starling.app/Starling"
symbols="$(nm "$binary")"

# A stripped binary would also pass, so first prove there are symbols.
case "$symbols" in
  *StarlingCore*) ;;
  *) echo "No StarlingCore symbols in $binary; cannot check for the Developer section."; exit 1 ;;
esac

# Captured once and matched in the shell itself: no pipe can lose a match to
# SIGPIPE, and no temporary file can fail inside a condition.
text_in_binary="$(strings "$binary")"
for name in DeveloperView DebugHarness DemoDriver LifecycleSelfTest DebugPermissionAccess; do
  case "$symbols" in
    *"$name"*) echo "Release contains $name (ADR 0015)."; exit 1 ;;
  esac
done
for text in "This is a test build" "doesn't hide free times" "scripted services"; do
  case "$text_in_binary" in
    *"$text"*) echo "Release contains the notice \"$text\" (ADR 0015)."; exit 1 ;;
  esac
done
echo "Release has no Developer section and no test-build notices."
