#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 tests/app-identity/check.py
bash -n scripts/build-app.sh scripts/notarize.sh
