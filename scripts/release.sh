#!/usr/bin/env bash
# Builds a release Trot.app and zips it for distribution:
#   scripts/release.sh            -> build/Trot-<version>.zip
# The version comes from scripts/bundle.sh (TROT_VERSION overrides it).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TROT_OUT:-$ROOT/build}"

"$ROOT/scripts/test.sh" >/dev/null
"$ROOT/scripts/bundle.sh" release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$OUT/Trot.app/Contents/Info.plist")"
ZIP="$OUT/Trot-$VERSION.zip"
rm -f "$ZIP"
# ditto keeps the bundle's resource forks and signature intact, unlike zip.
ditto -c -k --keepParent "$OUT/Trot.app" "$ZIP"
echo "==> $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "    shasum: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
