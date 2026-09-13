#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/support/kit-sources.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc "${kit_flags[@]}" -swift-version 6 -warnings-as-errors "${kit_sources[@]}" \
 Sources/Switch2KitApp/Runtime/RuntimeCompatibility.swift \
 tests/runtime-qualification/RuntimeTests.swift -o "$work/check"
"$work/check"
python3 - <<'PY'
from pathlib import Path
base = Path('Sources/Switch2KitApp')
entry = (base/'Runtime/ApplicationEntry.swift').read_text()
assert entry.index('contains("--runtime-check")') < entry.index('Switch2KitApp.main()')
assert '@main' not in (base/'Switch2KitApp.swift').read_text()
assert 'BridgeEngine(' not in entry and 'UserDefaults' not in entry
print('PASS isolated packaged-app probe entry wiring')
PY
