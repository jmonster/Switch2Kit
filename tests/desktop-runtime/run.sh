#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
python3 "$ROOT/tests/desktop-runtime/test_staging.py"
