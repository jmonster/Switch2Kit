#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source tests/support/kit-sources.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc "${kit_flags[@]}" -swift-version 6 -warnings-as-errors \
 "${kit_sources[@]}" \
 Sources/Switch2KitApp/Runtime/OutputHealth.swift \
 Sources/Switch2KitApp/Runtime/SupportSummary.swift tests/support-summary/Tests.swift -o "$work/tests"
"$work/tests"
