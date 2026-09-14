#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/Switch2Kit motion profiles.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
bash "$ROOT/tools/motion-calibration/build.sh" "$WORK/s2k-calibrate"
BIN=$(swift build --package-path "$ROOT" --show-bin-path)
INCLUDE="$ROOT/Sources/Switch2KitCABI/include"
SWIFT_TARGET=()
if [ "$(uname -s)" = Darwin ]; then SWIFT_TARGET=(-target "$(uname -m)-apple-macosx15.0"); fi
COMMON=(-Wall -Wextra -Werror -pthread -I "$INCLUDE" -L "$BIN" -lSwitch2KitC -Wl,-rpath,"$BIN")
cc -std=c11 "$ROOT/tests/motion-profiles/consumer.c" "${COMMON[@]}" -lm -o "$WORK/c-consumer"
c++ -std=c++17 -x c++ "$ROOT/tests/motion-profiles/consumer.c" "${COMMON[@]}" -o "$WORK/cpp-consumer"
swiftc "${SWIFT_TARGET[@]}" -swift-version 6 -warnings-as-errors -I "$BIN/Modules" -I "$INCLUDE" \
  -L "$BIN" -lSwitch2KitC -Xlinker -rpath -Xlinker "$BIN" \
  "$ROOT/tools/motion-calibration/Calibration.swift" "$ROOT/tools/motion-calibration/Capture.swift" \
  "$ROOT/tests/motion-profiles/prompt.swift" -o "$WORK/prompt-regression"
"$WORK/prompt-regression"
swiftc "${SWIFT_TARGET[@]}" -swift-version 6 -warnings-as-errors -I "$BIN/Modules" -I "$INCLUDE" \
  -L "$BIN" -lSwitch2KitC -Xlinker -rpath -Xlinker "$BIN" \
  "$ROOT/tools/motion-calibration/Calibration.swift" "$ROOT/tests/motion-profiles/solver.swift" -o "$WORK/solver-regression"
"$WORK/solver-regression"
for CONSUMER in "$WORK/c-consumer" "$WORK/cpp-consumer"; do
  S2K_CALIBRATION_TOOL="$WORK/s2k-calibrate" S2K_PROFILE_C_CONSUMER="$CONSUMER" \
    PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/motion-profiles/test_tool.py"
done
