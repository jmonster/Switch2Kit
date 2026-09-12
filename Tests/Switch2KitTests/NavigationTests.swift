import Foundation
import XCTest
import Switch2Kit
@testable import Switch2KitNavigationExample

final class NavigationTests: XCTestCase {
    func testNeutralArmingAndHysteresis() {
        var router = NavigationRouter(); router.setActive(true)
        XCTAssertEqual(router.receive(.init(actions: [.activate]), from: .keyboard, at: 0), [])
        XCTAssertEqual(router.receive(.init(), from: .keyboard, at: 1), [])
        XCTAssertEqual(router.receive(.init(stick: .init(x: 0.54)), from: .keyboard, at: 2), [])
        XCTAssertEqual(router.receive(.init(stick: .init(x: 0.55)), from: .keyboard, at: 3), [.right])
        XCTAssertEqual(router.receive(.init(stick: .init(x: 0.4)), from: .keyboard, at: 3.1), [])
        XCTAssertEqual(router.tick(at: 3.41), [.right])
        XCTAssertEqual(router.receive(.init(stick: .init(x: 0.34)), from: .keyboard, at: 3.5), [])
        XCTAssertEqual(router.tick(at: 4), [])
        XCTAssertEqual(router.receive(.init(stick: .init(x: 0.4)), from: .keyboard, at: 5), [])
    }
    func testEdgesRepeatsAndStallsDoNotRepeatActivation() {
        var router = NavigationRouter(); router.setActive(true)
        _ = router.receive(.init(), from: .keyboard, at: 0)
        XCTAssertEqual(router.receive(.init(actions: [.up, .activate]), from: .keyboard, at: 1), [.up, .activate])
        XCTAssertEqual(router.receive(.init(actions: [.up, .activate]), from: .keyboard, at: 1.1), [])
        XCTAssertEqual(router.tick(at: 1.39), [])
        XCTAssertEqual(router.tick(at: 1.4), [.up])
        XCTAssertEqual(router.tick(at: 1.45), [])
        XCTAssertEqual(router.tick(at: 30), [.up])
        XCTAssertEqual(router.tick(at: 30), [])
        _ = router.receive(.init(), from: .keyboard, at: 31)
        XCTAssertEqual(router.tick(at: 40), [])
        XCTAssertEqual(router.receive(.init(actions: [.activate, .back]), from: .keyboard, at: 41), [.activate, .back])
    }
    func testInactiveAndResynchronizationRequireNeutral() {
        var router = NavigationRouter()
        XCTAssertEqual(router.receive(.init(actions: [.up]), from: .keyboard, at: 0), [])
        router.setActive(true)
        _ = router.receive(.init(), from: .keyboard, at: 1)
        XCTAssertEqual(router.receive(.init(actions: [.up]), from: .keyboard, at: 2), [.up])
        router.setActive(false)
        XCTAssertEqual(router.tick(at: 10), [])
        router.setActive(true)
        XCTAssertEqual(router.receive(.init(actions: [.up]), from: .keyboard, at: 11), [])
        _ = router.receive(.init(), from: .keyboard, at: 12)
        XCTAssertEqual(router.receive(.init(actions: [.up]), from: .keyboard, at: 13), [.up])
        router.reset()
        XCTAssertEqual(router.tick(at: 30), [])
        XCTAssertEqual(router.receive(.init(actions: [.activate]), from: .keyboard, at: 31), [])
    }
    func testMultipleSourcesOppositesAndDisconnectOwnership() {
        let pad = NavigationSource.gameController(UUID())
        var router = NavigationRouter(); router.setActive(true)
        _ = router.receive(.init(), from: .keyboard, at: 0)
        _ = router.receive(.init(), from: pad, at: 0)
        XCTAssertEqual(router.receive(.init(actions: [.right]), from: .keyboard, at: 1), [.right])
        XCTAssertEqual(router.receive(.init(actions: [.right]), from: pad, at: 2), [])
        router.remove(.keyboard)
        XCTAssertEqual(router.tick(at: 3), [.right])
        router.remove(pad)
        XCTAssertEqual(router.tick(at: 4), [])
        _ = router.receive(.init(), from: pad, at: 5)
        XCTAssertEqual(router.receive(.init(actions: [.left, .right]), from: pad, at: 6), [])
        XCTAssertEqual(router.tick(at: 7), [])
    }
    func testKitAdapterAndAdmissionBounds() {
        let state = Switch2ControllerState(buttons: [.a, .b, .dpadUp], rightStick: .init(x: -1))
        let input = NavigationInput(state)
        XCTAssertEqual(input.actions, [.up, .activate, .back])
        XCTAssertEqual(input.stick.x, -1)
        var router = NavigationRouter(); router.setActive(true)
        let identities = (0..<65).map { _ in NavigationSource.gameController(UUID()) }
        for id in identities { _ = router.receive(.init(), from: id, at: 0) }
        XCTAssertEqual(router.receive(.init(actions: [.activate]), from: identities[64], at: 1), [])
        router.remove(identities[0])
        _ = router.receive(.init(), from: identities[64], at: 2)
        XCTAssertEqual(router.receive(.init(actions: [.activate]), from: identities[64], at: 3), [.activate])
        XCTAssertEqual(router.tick(at: .infinity), [])
    }
}
