import Foundation

enum CGEventType { case leftMouseDown, leftMouseUp, rightMouseDown, rightMouseUp, leftMouseDragged, rightMouseDragged, mouseMoved }
enum CGMouseButton { case left, right }
enum CGEventField { case mouseEventDeltaX, mouseEventDeltaY }
enum CGEventTapLocation { case cghidEventTap }
final class CGEvent {
    static var cursor = CGPoint(x: 100, y: 100)
    static var allowCreation = true
    static var lastDeltaX: Int64 = 0
    private var deltaX: Int64 = 0
    var location: CGPoint
    init?(source: AnyObject?) { location = Self.cursor }
    init?(mouseEventSource: AnyObject?, mouseType: CGEventType, mouseCursorPosition: CGPoint, mouseButton: CGMouseButton) {
        guard Self.allowCreation else { return nil }
        location = mouseCursorPosition
    }
    func setIntegerValueField(_ field: CGEventField, value: Int64) { if field == .mouseEventDeltaX { deltaX = value } }
    func post(tap: CGEventTapLocation) { Self.cursor = location; Self.lastDeltaX = deltaX }
}
@main enum MouseTests {
    static func main() {
        let mouse = MouseController()
        mouse.updateContext(permission: true, screens: [CGRect(x: 0, y: 0, width: 200, height: 200)])
        var config = ControllerConfiguration(); config.mouseEnabled = true
        var state = ControllerState(); state.mouseX = 1000; state.mouseY = 1000; state.liftDistance = 10
        func input() -> Bool { mouse.handle(serial: "test", model: .joyCon2Right, state: state, configuration: config) }
        precondition(!input(), "The first sample only primes counters")
        state.mouseX += 10
        precondition(input() && CGEvent.cursor.x == 103)
        precondition(!input(), "Stationary reports are not activity")
        state.liftDistance = 0; state.mouseX += 100
        precondition(!input())
        state.liftDistance = 10; state.surfaceQuality = 5000; state.mouseX += 100
        precondition(!input())
        state.surfaceQuality = 0; config.mouseEnabled = false; state.mouseX += 100
        precondition(!input())
        config.mouseEnabled = true; precondition(!input())
        mouse.updateContext(permission: false, screens: []); state.mouseX += 100
        precondition(!input())
        mouse.updateContext(permission: true, screens: [CGRect(x: 0, y: 0, width: 200, height: 200)])
        state.mouseX = UInt16.max; precondition(!input())
        state.mouseX = 3; precondition(input(), "Counter wrap must retain accepted motion")
        CGEvent.cursor = CGPoint(x: 199, y: 100); state.mouseX += 10
        precondition(input() && CGEvent.cursor.x == 199 && CGEvent.lastDeltaX == 3,
                     "Cursor clamping must preserve relative mouse events for games")
        CGEvent.cursor = CGPoint(x: 100, y: 100); CGEvent.allowCreation = false; state.mouseX += 10
        precondition(!input(), "Failed event creation is not activity")
        CGEvent.allowCreation = true; mouse.reset(); config.mouseSensitivity = 0.1
        precondition(!input())
        for _ in 0..<1000 {
            state.mouseX += 1; precondition(!input())
            state.mouseX -= 1; precondition(!input())
        }
        precondition(!mouse.handle(serial: "pro", model: .proController2, state: state, configuration: config))
        surfaceReacquisition()
        print("PASS accepted pointer motion, noise, lift/quality, wrap, disabled/denied, edge clamping and event failure")
    }
    static func surfaceReacquisition() {
        for model in [Switch2.Model.joyCon2Left, .joyCon2Right] {
            let mouse = MouseController()
            mouse.updateContext(permission: true, screens: [])
            var config = ControllerConfiguration(); config.mouseEnabled = true
            var state = ControllerState()
            func input() -> Bool {
                mouse.handle(serial: "surface-test", model: model, state: state, configuration: config)
            }
            CGEvent.cursor = CGPoint(x: 100, y: 100)
            state.mouseX = 1000; state.mouseY = 2000
            // An initial no-surface report must not prime a usable counter baseline.
            precondition(!input())
            state.liftDistance = 10; state.mouseX = 40000; state.mouseY = 100
            precondition(!input() && CGEvent.cursor == CGPoint(x: 100, y: 100),
                         "First contact after lifted reports only establishes the optical baseline")
            state.mouseX += 10
            precondition(input() && CGEvent.cursor.x == 103)
            for invalid in 0..<3 {
                let before = CGEvent.cursor
                state.liftDistance = invalid == 0 ? 0 : invalid == 1 ? 1000 : 10
                state.surfaceQuality = invalid == 2 ? 4000 : 0
                state.mouseX &+= 30000; state.mouseY &+= 30000
                precondition(!input() && CGEvent.cursor == before)
                // Counters may jump, including wrapping, while tracking was unusable.
                state.liftDistance = 10; state.surfaceQuality = 0
                state.mouseX = UInt16.max; state.mouseY = 500
                precondition(!input() && CGEvent.cursor == before,
                             "Reacquisition cannot turn an untracked interval into pointer movement")
                state.mouseX = 3
                precondition(input() && CGEvent.cursor.x == before.x + 1,
                             "A following tracked report retains modulo counter movement")
                // No fractional residue from before loss or the discarded interval survives.
                state.mouseX += 1
                precondition(!input())
            }
            mouse.reset()
        }
        print("PASS both Joy-Con halves re-prime after lift, out-of-range surface and low quality")
    }

}
