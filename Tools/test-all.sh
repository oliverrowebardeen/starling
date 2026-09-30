#!/usr/bin/env bash
# Runs every package's tests with warnings treated as errors.
# Usage: Tools/test-all.sh [package-name ...]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

packages=("$@")
if [ ${#packages[@]} -eq 0 ]; then
  for manifest in "$root"/Packages/*/Package.swift "$root"/Tools/*/Package.swift; do
    [ -f "$manifest" ] && packages+=("$(dirname "$manifest")")
  done
fi

failed=()
for package in "${packages[@]}"; do
  [ -d "$package" ] || package="$root/Packages/$package"
  name="$(basename "$package")"
  echo "==> $name"
  if (cd "$package" && swift build --build-tests -Xswiftc -warnings-as-errors && swift test --skip-build); then
    echo "==> $name: passed"
  else
    echo "==> $name: FAILED"
    failed+=("$name")
  fi
done

if [ ${#failed[@]} -gt 0 ]; then
  echo "Failed: ${failed[*]}"
  exit 1
fi
echo "All packages passed."
