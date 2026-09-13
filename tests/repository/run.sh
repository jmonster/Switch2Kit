#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 -m unittest discover -s tests/repository -p 'test_*.py'
