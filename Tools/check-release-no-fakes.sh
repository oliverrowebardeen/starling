#!/usr/bin/env bash
# Builds the app's Release configuration for the iOS Simulator and fails if
# any test-double module is linked in (ADR 0140): StarlingFakes, or any other
# module whose name ends in Fakes, such as StarlingAvailabilityFakes. Only a
# real Release build can show that the exclusion still holds.
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

# Swift mangles a module name as its length and then the name, for example
# 15StarlingFakes or 25StarlingAvailabilityFakes.
pattern='[0-9]+[A-Z][A-Za-z0-9]*Fakes'
fakes="$(grep -cE "$pattern" <<<"$symbols" || true)"
if [ "$fakes" != 0 ]; then
  echo "Release links $fakes symbols from a Fakes module (ADR 0140), for example:"
  grep -E "$pattern" <<<"$symbols" | head -5
  exit 1
fi
echo "Release has no StarlingFakes symbols and no other Fakes module."
