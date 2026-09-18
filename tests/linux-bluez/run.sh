#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
[ "$(uname -s)" = Linux ] || { echo 'SKIP Linux BlueZ radio tests on this platform'; exit 0; }
command -v dbus-daemon >/dev/null
python3 "$ROOT/tests/linux-bluez/test_build.py"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swift build --package-path "$ROOT" --product Switch2KitC -Xswiftc -warnings-as-errors -j 2
BIN=$(swift build --package-path "$ROOT" --show-bin-path)
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -pthread \
  -I "$ROOT/Sources/Switch2KitCABI/include" "$ROOT/tests/linux-bluez/consumer.cpp" \
  -L "$BIN" -lSwitch2KitC -Wl,-rpath,"$BIN" -o "$WORK/consumer"
python3 "$ROOT/tests/linux-bluez/run.py" --binary "$WORK/consumer" "$@"
