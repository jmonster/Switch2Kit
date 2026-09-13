#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 tests/emulator-host/patch_tests.py

PYTHONDONTWRITEBYTECODE=1 python3 tests/emulator-host/bundle_tests.py
PYTHONDONTWRITEBYTECODE=1 python3 tests/emulator-host/inspection_tests.py
