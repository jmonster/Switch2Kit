#!/bin/bash
# Build a fresh source consumer with no dependency on the dashboard.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
[ "$(uname -s)" = Darwin ] || { echo 'Consumer verification requires macOS and Xcode.' >&2; exit 2; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/source/Sources/Consumer"
python3 - "$ROOT" "$WORK/source/Package.swift" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "IndependentConsumer", platforms: [.macOS(.v15)],
    dependencies: [.package(path: %s)],
    targets: [.executableTarget(name: "Consumer", dependencies: [.product(name: "Switch2Kit", package: %s)])])
''' % (json.dumps(str(root)), json.dumps(root.name.lower())))
PY
cat > "$WORK/source/Sources/Consumer/main.swift" <<'SWIFT'
import Foundation
import Switch2Kit

@MainActor
func checkConsumerAPI() throws {
    let manager = Switch2ControllerManager(configuration: .init(discoveryMode: .onDemand))
    let snapshot: Switch2ManagerSnapshot = manager.snapshot
    let observation = try manager.observe(on: DispatchQueue(label: "independent.consumer"), bufferingNewest: 8) { event in
        if case .input(let controller) = event {
            let _: Switch2ControllerID = controller.id
            let _: Switch2Buttons = controller.state.buttons
            let _: Switch2Stick? = controller.state.leftStick
            let _: UInt64 = controller.state.sequence
        }
    }
    let start: () -> Void = manager.start
    let discover: (TimeInterval) throws -> Void = { try manager.discover(for: $0) }
    let rumble: (Switch2ControllerID) throws -> Void = { try manager.pulseRumble(for: $0, strong: 0.2, duration: 0.12) }
    let feedback: (Switch2ControllerID) throws -> Void = { try manager.playRumble(for: $0, intensity: 0.3) }
    _ = (snapshot, observation, start, discover, rumble, feedback)
    observation.cancel()
}
// Build/link only. No controller-support method is executed in this consumer.
SWIFT
swift package --package-path "$WORK/source" describe
swift build --package-path "$WORK/source" -Xswiftc -warnings-as-errors
BIN=$(swift build --package-path "$WORK/source" --show-bin-path)
if otool -L "$BIN/Consumer" | grep -q CoreHID; then
    echo 'Independent source consumer unexpectedly links CoreHID.' >&2; exit 1
fi
echo 'PASS fresh SwiftPM source consumer (no radio opened)'
