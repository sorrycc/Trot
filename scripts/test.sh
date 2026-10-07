#!/usr/bin/env bash
# Runs the unit tests: scripts/test.sh [extra swift test arguments]
# With only the Command Line Tools installed, Swift Testing lives outside the
# default search paths, so they are added here. Xcode needs none of this.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV="$(xcode-select -p)"
FLAGS=()
if [ -d "$DEV/Library/Developer/Frameworks/Testing.framework" ]; then
    FRAMEWORKS="$DEV/Library/Developer/Frameworks"
    LIBS="$DEV/Library/Developer/usr/lib"
    FLAGS=(-Xswiftc "-F$FRAMEWORKS" -Xlinker "-F$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$LIBS")
fi
exec swift test --package-path "$ROOT/app" ${FLAGS[@]+"${FLAGS[@]}"} "$@"
