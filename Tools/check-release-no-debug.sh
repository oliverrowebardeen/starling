#!/usr/bin/env bash
# Fails if a Release build contains the Debug-only Developer section or a
# test-build notice (ADR 0015 decision 5, requested by lane P15-A). Reuses
# the Release build that check-release-no-fakes.sh makes, so run that first.
# Not yet in CI or the local gate: main's Phase 1 app still has the Developer
# section in Release until lane P15-A's shell lands, and wiring it now would
# fail every lane's gate. The Orchestrator wires it when that PR merges.
# Usage: Tools/check-release-no-debug.sh [derived-data-path]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
derived="${1:-$root/.build/app-release}"
binary="$derived/Build/Products/Release-iphonesimulator/Starling.app/Starling"
symbols="$(nm "$binary")"

# A stripped binary would also pass, so first prove there are symbols.
if ! grep -q StarlingCore <<<"$symbols"; then
  echo "No StarlingCore symbols in $binary; cannot check for the Developer section."
  exit 1
fi

for name in DeveloperView DebugHarness DemoDriver LifecycleSelfTest DebugPermissionAccess; do
  if grep -q "$name" <<<"$symbols"; then
    echo "Release contains $name (ADR 0015)."
    exit 1
  fi
done
# Capture once: with pipefail, `strings | grep -q` can report a match as a
# failure when grep exits early and strings gets SIGPIPE.
text_in_binary="$(strings "$binary")"
for text in "This is a test build" "doesn't hide free times" "scripted services"; do
  if grep -qF "$text" <<<"$text_in_binary"; then
    echo "Release contains the notice \"$text\" (ADR 0015)."
    exit 1
  fi
done
echo "Release has no Developer section and no test-build notices."
