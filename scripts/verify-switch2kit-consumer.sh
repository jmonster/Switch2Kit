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

// Compile against public declarations only; no testable import or example helper.
enum AppCommand: Hashable, Sendable { case confirm, cancel }
func checkActionAPI() throws {
    var router = try Switch2ActionRouter(actions: [AppCommand.confirm, .cancel], bindings: [
        .init(.confirm, from: .buttons(.a)), .init(.cancel, from: .buttons(.b))])
    _ = router.setActive(true)
    _ = router.receive(Switch2ControllerState(), from: .keyboard, at: 0)
    let events: [Switch2ActionEvent<AppCommand>] = router.receive([.confirm], from: .keyboard, at: 1)
    for event in events { _ = (event.action, event.phase) }
    _ = router.tick(at: 3)
    _ = try router.replaceBindings([.init(.confirm, from: .axis(.primaryX, positive: true))])
    _ = router.remove(.keyboard)
    _ = router.reset()
    var navigation = Switch2ActionRouter<Switch2NavigationAction>.navigation()
    _ = navigation.setActive(false)
}

func checkActionEventAPI(_ event: Switch2ControllerEvent) {
    var router = Switch2ActionRouter<Switch2NavigationAction>.navigation()
    _ = router.setActive(true)
    _ = router.receive(event, at: 0)
}

func checkMotionAPI(_ raw: Switch2Motion) throws -> Switch2CalibratedMotion {
    // Synthetic calibration only: prove public source integration, not device gains.
    let acceleration = try Switch2SensorCalibration(
        negativeReference: .init(x: -1000, y: -2000, z: -3000),
        positiveReference: .init(x: 1000, y: 2000, z: 3000), magnitude: 9.80665)
    let gyro = try Switch2SensorCalibration(offset: .init(x: 1, y: 2, z: 3),
        unitsPerCount: .init(x: 0.01, y: 0.01, z: 0.01),
        xAxis: .negativeY, yAxis: .positiveZ, zAxis: .positiveX)
    return Switch2MotionCalibration(acceleration: acceleration, angularVelocity: gyro).apply(to: raw)
}

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
