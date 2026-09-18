#!/bin/bash
# Optional queue-only microbenchmark; not a hardware latency or CI timing assertion.
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/support/kit-sources.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc "${kit_flags[@]}" -swift-version 6 -O -warnings-as-errors "${kit_sources[@]}" \
    Sources/Switch2Kit/Public/Observation.swift tests/observation-buffer/Benchmark.swift \
    -o "$work/benchmark"
"$work/benchmark"
