#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 tests/repository/check.py
