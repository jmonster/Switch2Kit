#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -package-name Switch2Kit Sources/Switch2Kit/Platform/ControllerLock.swift -swift-version 6 -warnings-as-errors \
 Sources/Switch2KitApp/Runtime/VisualizerMailbox.swift \
 tests/visualizer/VisualizerTests.swift -o "$work/check"
"$work/check"
