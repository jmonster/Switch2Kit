#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
command -v cmake >/dev/null || { echo 'C ABI tests require CMake 3.24+' >&2; exit 2; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cmake -S "$ROOT/tests/c-consumer" -B "$WORK" -DCMAKE_BUILD_TYPE=Release
cmake --build "$WORK" --parallel 2
ctest --test-dir "$WORK" --output-on-failure
if [ "$(uname -s)" = Darwin ]; then
  LIB=$(find "$WORK/switch2kit/swift" -name libSwitch2KitC.dylib -type f | head -1)
  otool -L "$LIB"
  if otool -L "$LIB" | grep -E 'CoreHID|Switch2KitApp'; then exit 1; fi
fi
