#!/bin/bash
# Test the production Swift 6 package, then the platform/output boundary suites.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test -Xswiftc -warnings-as-errors
for suite in tests/*/run.sh; do
  [ -f "$suite" ] || continue
  bash "$suite"
done
