"""Reviewed final source-boundary and host-identity edits on the extraction branch."""
from pathlib import Path
root = Path('.')

def replace(path, old, new):
    p = root / path
    source = p.read_text()
    assert old in source, f'Missing expected text in {path}'
    p.write_text(source.replace(old, new))

p = root / 'Sources/Switch2Kit/Bluetooth/ControllerTransport.swift'
s = p.read_text()
s = s.replace('    private let rumbleInbox = Mutex(RumbleInbox())', '''    private let rumbleInbox = Mutex(RumbleInbox())
    private struct ControlIntent: Sendable {
        let id: Switch2ControllerID
        let generation: UUID?
        let operation: @Sendable (ControllerSession) -> Void
    }
    private struct ControlInbox: Sendable {
        var pending: [ControlIntent] = []
        var scheduled = false
        var overflowed = false
    }
    private let controlInbox = Mutex(ControlInbox())''')
s = s.replace('            rumbleInbox.withLock { $0.pending.removeAll() }', '            rumbleInbox.withLock { $0.pending.removeAll() }\n            controlInbox.withLock { $0.pending.removeAll(); $0.overflowed = false }')
a = s.index('    // Only package companion operations may use this queue-confined seam.')
b = s.index('    package func failure(', a)
s = s[:a] + '''    // Bounded ingress for LEDs/RSSI/companions. The generation is captured at
    // submission, so a delayed control request cannot act on a replacement link.
    // Operations are library/companion code, never arbitrary public host handlers.
    package func withSession(_ id: Switch2ControllerID, operation: @escaping @Sendable (ControllerSession) -> Void) {
        let generation = hub.snapshot.controllers.first { $0.id == id }?.sessionGeneration
        let schedule = controlInbox.withLock { inbox in
            if inbox.pending.count < 128 {
                inbox.pending.append(ControlIntent(id: id, generation: generation, operation: operation))
            } else { inbox.overflowed = true }
            guard !inbox.scheduled else { return false }
            inbox.scheduled = true; return true
        }
        if schedule { btQueue.async { [weak self] in self?.drainControls() } }
    }
    private func drainControls() {
        let (batch, overflowed) = controlInbox.withLock { inbox in
            let batch = Array(inbox.pending.prefix(32))
            inbox.pending.removeFirst(batch.count)
            let overflowed = inbox.overflowed; inbox.overflowed = false
            return (batch, overflowed)
        }
        if overflowed { failure(nil, .operationQueueFull) }
        for request in batch {
            guard let session = sessions.values.first(where: { $0.peripheral.identifier == request.id.rawValue }),
                  !session.isRetired, session.lifetime.id == request.generation else {
                failure(request.id, .controllerNotReady); continue
            }
            request.operation(session)
        }
        let again = controlInbox.withLock { inbox in
            if inbox.pending.isEmpty && !inbox.overflowed { inbox.scheduled = false; return false }
            return true
        }
        if again { btQueue.async { [weak self] in self?.drainControls() } }
    }
''' + s[b:]
old = '''              manu.count > 2,
              Switch2.u16(manu, 0) == Switch2.nintendoCompanyID,
              let adv = Switch2.parseAdvertisement(manufacturerData: manu.dropFirst(2)),'''
assert old in s
s = s.replace(old, '              let adv = Switch2.recognizeAdvertisement(manu),')
p.write_text(s)
replace('Sources/Switch2Kit/Public/Lifecycle.swift', '    case observerLimitReached', '    case observerLimitReached\n    /// More than 128 pending LED/RSSI/experimental operations; some requests were rejected.\n    case operationQueueFull')
replace('Sources/Switch2Kit/Diagnostics/Diagnostics.swift', 'String(message.prefix(512))', 'String(String(decoding: message.utf8.prefix(2048), as: UTF8.self).prefix(512))')
replace('tests/engine/run.sh', 'tests/engine/RetryTests.swift; do', 'tests/engine/RetryTests.swift tests/engine/ControlIngressTests.swift; do')
replace('tests/support/kit-sources.sh', '  Sources/Switch2Kit/Protocol/Switch2Protocol.swift', '  Sources/Switch2Kit/Protocol/Switch2Protocol.swift\n  Sources/Switch2Kit/Protocol/AdvertisementRecognition.swift')
replace('Examples/NavigationSupport/NavigationRouter.swift', '    var repeats: Bool', '    package var repeats: Bool')
replace('Examples/Switch2KitDemo/DemoModel.swift', '''            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.key(event)
            }''', '''            // Keep NSEvent inside the local AppKit callback. Only a Sendable Bool
            // crosses assumeIsolated's result boundary; NSEvent is not Sendable.
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.key(event) == nil
            }
            return consumed ? nil : event''')
# Explicit owner-requested correction, NOT an implicit library integration change.
# Keep existing signing/notarization checks; update their expected host identity.
# Do not alter updater policy, entitlements, log directories or settings archives.
for name in ['Resources/Info.plist',
             'Sources/FinallyTheControllerWorks/Runtime/RuntimeCompatibility.swift',
             'Sources/FinallyTheControllerWorks/UI/AboutAndOnboarding.swift',
             'scripts/notarize-release.py', 'tests/runtime-qualification/RuntimeTests.swift',
             'tests/release/run.sh', 'tests/fork/check.py']:
    replace(name, 'io.github.jmonster.switch2mac', 'wabisabi.ware.gamecubed')
