#!/usr/bin/env bash
# Builds the app's Release configuration for the iOS Simulator and fails if
# any StarlingFakes symbol is linked in (ADR 0140). The exclusion relies on
# Xcode naming the linked object StarlingFakes.o, so only a real Release build
# can show that it still holds.
# Expects App/Starling.xcodeproj to exist (xcodegen generate --spec App/project.yml).
# Usage: Tools/check-release-no-fakes.sh [derived-data-path]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
derived="${1:-$root/.build/app-release}"

xcodebuild build -quiet \
  -project "$root/App/Starling.xcodeproj" -scheme Starling -configuration Release \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

binary="$derived/Build/Products/Release-iphonesimulator/Starling.app/Starling"
# Exits here if the binary is missing or unreadable, instead of counting zero.
symbols="$(nm "$binary")"

# A stripped binary would also show no fakes, so first prove the symbols
# are there to search.
if ! grep -q StarlingCore <<<"$symbols"; then
  echo "No StarlingCore symbols in $binary; cannot check for fakes."
  exit 1
fi

fakes="$(grep -c StarlingFakes <<<"$symbols" || true)"
if [ "$fakes" != 0 ]; then
  echo "Release links $fakes StarlingFakes symbols (ADR 0140), for example:"
  grep StarlingFakes <<<"$symbols" | head -5
  exit 1
fi
echo "Release has no StarlingFakes symbols."
