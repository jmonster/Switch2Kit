#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
[ "$#" -eq 1 ] || { echo 'Usage: bash tools/motion-calibration/build.sh /chosen/output/executable' >&2; exit 2; }
OUTPUT=$1
[ ! -e "$OUTPUT" ] && [ ! -L "$OUTPUT" ] || { echo 'Refusing to overwrite the output.' >&2; exit 2; }
# Uses the source-built native product. No package-name override, second backend or new SwiftPM product.
swift build --package-path "$ROOT" --product Switch2KitC -Xswiftc -warnings-as-errors
BIN=$(swift build --package-path "$ROOT" --show-bin-path)
ARGS=(-swift-version 6 -warnings-as-errors -I "$BIN/Modules" -I "$ROOT/Sources/Switch2KitCABI/include" -I "$ROOT/Sources/Switch2KitDBus/include"
      -L "$BIN" -lSwitch2KitC -Xlinker -rpath -Xlinker "$BIN")
if [ "$(uname -s)" = Darwin ]; then
  ARGS+=(-target "$(uname -m)-apple-macosx15.0" -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist
         -Xlinker "$ROOT/tools/motion-calibration/Info.plist")
fi
swiftc "${ARGS[@]}" "$ROOT/tools/motion-calibration/Calibration.swift" \
  "$ROOT/tools/motion-calibration/Capture.swift" "$ROOT/tools/motion-calibration/main.swift" -o "$OUTPUT"
echo 'Built calibration tool; linked to this checkout. This is not a redistributable application bundle.'
