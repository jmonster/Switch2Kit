#!/bin/bash
set -euo pipefail
python3 "$(dirname "$0")/test_launch.py"
python3 "$(dirname "$0")/test_linux.py"
