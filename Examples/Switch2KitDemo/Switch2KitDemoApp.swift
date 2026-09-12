import AppKit
import SwiftUI
import Switch2Kit

@main
struct Switch2KitDemoApp: App {
    @NSApplicationDelegateAdaptor(DemoDelegate.self) private var delegate
    @StateObject private var model = DemoModel()
    var body: some Scene {
        WindowGroup("Switch2Kit — In-process Controller Demo") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Switch2Kit").font(.largeTitle)
                Text("Navigation stays inside this application. No Accessibility permission or virtual gamepad is used.")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
                    ForEach(0..<9) { index in
                        Text("Item \(index + 1)").frame(maxWidth: .infinity).padding(8)
                            .background(model.selection == index ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.1))
                            .accessibilityLabel("Item \(index + 1)\(model.selection == index ? ", selected" : "")")
                    }
                }
                Text(model.lastCommand)
                Text("Release controls after reconnect or focus changes. Directions repeat; A/Return and B/Escape do not.").font(.caption)
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                ControllerPanel(manager: model.manager, model: model)
            }
            .padding(20).frame(minWidth: 720, minHeight: 620)
            .onAppear { delegate.model = model; model.start() }
        }
    }
}

@MainActor
private final class DemoDelegate: NSObject, NSApplicationDelegate {
    weak var model: DemoModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.prepareToQuit { Task { @MainActor in NSApp.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private struct ControllerPanel: View {
    @ObservedObject var manager: Switch2ControllerManager
    @ObservedObject var model: DemoModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bluetooth: \(manager.bluetoothState.rawValue) | Discovery: \(String(describing: manager.discoveryState))")
            HStack {
                Button("Start") { model.start() }
                Button("Find Controllers for 60 Seconds") { model.discover() }
                Button("Stop Support") { Task { await model.stop() } }
            }
            Text("Hold Sync for first connection. This does not create a system GCController or grant other apps input.")
                .font(.callout)
            List(manager.controllers) { controller in
                VStack(alignment: .leading, spacing: 6) {
                    Text(controller.name).font(.headline)
                    Text("Buttons: 0x\(String(controller.state.buttons.rawValue, radix: 16)) | report \(controller.state.sequence)")
                    Text("Left: \(stick(controller.state.leftStick))   Right: \(stick(controller.state.rightStick))")
                    Text("L: \(trigger(controller.state.leftTrigger))   R: \(trigger(controller.state.rightTrigger))")
                    Text("Battery: \(controller.state.battery.millivolts.map { String($0) + " mV" } ?? "unavailable")")
                    HStack {
                        Button("Short Rumble") {
                            do { try manager.pulseRumble(for: controller.id, strong: 0.4, weak: 0.4, duration: 0.15) }
                            catch { model.errorMessage = String(describing: error) }
                        }.disabled(!controller.capabilities.contains(.rumble))
                        Button("Disconnect") { manager.disconnect(controller.id) }
                    }
                }.padding(.vertical, 6)
            }
        }
    }
    private func stick(_ value: Switch2Stick?) -> String {
        value.map { String(format: "(%+.2f, %+.2f)", $0.x, $0.y) } ?? "not present"
    }
    private func trigger(_ value: Switch2Trigger) -> String {
        (value.travel.map { String(format: "%.2f travel, ", $0) } ?? "") + (value.isPressed ? "pressed" : "released")
    }
}
