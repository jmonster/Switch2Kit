#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
PYTHONDONTWRITEBYTECODE=1 python3 tests/fixture-identity/test_identity.py
