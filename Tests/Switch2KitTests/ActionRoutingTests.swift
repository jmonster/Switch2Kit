import Foundation
import XCTest
@testable import Switch2Kit

final class ActionRoutingTests: XCTestCase {
    private typealias A = Switch2NavigationAction
    private typealias R = Switch2ActionRouter<A>
    private typealias E = Switch2ActionEvent<A>
    private func started() -> R { var r = R.navigation(); r.setActive(true); return r }
    private func state(_ buttons: Switch2Buttons = [], x: Double = 0, y: Double = 0) -> Switch2ControllerState {
        .init(buttons: buttons, leftStick: .init(x: x, y: y))
    }
    private func controller(_ id: Switch2ControllerID, connection: UUID, sequence: UInt64,
                            buttons: Switch2Buttons = []) -> Switch2Controller {
        .init(id: id, model: .proController2, state: .init(buttons: buttons, sequence: sequence),
              connectedAt: Date(timeIntervalSince1970: 0), bodyColor: nil, buttonColor: nil,
              serialNumber: nil, sessionGeneration: connection, lastActivityAt: 0)
    }

    func testNeutralArmingAndHysteresis() {
        var r = started()
        XCTAssertEqual(r.receive(state(.a), from: .keyboard, at: 0), [])
        XCTAssertEqual(r.receive(state(x: 0.4), from: .keyboard, at: 1), [])
        XCTAssertEqual(r.receive(state(x: 0.8), from: .keyboard, at: 2), [])
        _ = r.receive(state(), from: .keyboard, at: 3)
        XCTAssertEqual(r.receive(state(x: 0.54), from: .keyboard, at: 4), [])
        XCTAssertEqual(r.receive(state(x: 0.55), from: .keyboard, at: 5), [E(.right, phase: .pressed)])
        XCTAssertEqual(r.receive(state(x: 0.4), from: .keyboard, at: 5.1), [])
        XCTAssertEqual(r.tick(at: 5.41), [E(.right, phase: .repeated)])
        XCTAssertEqual(r.receive(state(x: 0.34), from: .keyboard, at: 5.5), [E(.right, phase: .released)])
        XCTAssertEqual(r.receive(state(x: 0.4), from: .keyboard, at: 6), [])
        XCTAssertEqual(r.tick(at: 7), [])
    }
    func testDeterministicPressReleaseOrderAndRepeatPolicy() {
        var r = started()
        _ = r.receive(Set<A>(), from: .keyboard, at: 0)
        XCTAssertEqual(r.receive([.activate, .up], from: .keyboard, at: 1),
                       [E(.up, phase: .pressed), E(.activate, phase: .pressed)])
        XCTAssertEqual(r.receive([.activate, .up], from: .keyboard, at: 1.1), [])
        XCTAssertEqual(r.tick(at: 1.39), [])
        XCTAssertEqual(r.tick(at: 1.4), [E(.up, phase: .repeated)])
        XCTAssertEqual(r.tick(at: 1.45), [])
        XCTAssertEqual(r.tick(at: 30), [E(.up, phase: .repeated)])
        XCTAssertEqual(r.tick(at: 30), [])
        XCTAssertEqual(r.receive([.back], from: .keyboard, at: 31),
                       [E(.up, phase: .released), E(.activate, phase: .released), E(.back, phase: .pressed)])
        XCTAssertEqual(r.tick(at: 40), [])
    }
    func testInactiveFocusAndContextReplacementReleaseAndRearm() {
        var r = R.navigation()
        XCTAssertEqual(r.receive(Set<A>(), from: .keyboard, at: 0), [])
        XCTAssertEqual(r.sourceCount, 0)
        r.setActive(true)
        _ = r.receive(Set<A>(), from: .keyboard, at: 1)
        _ = r.receive([.activate, .left], from: .keyboard, at: 2)
        XCTAssertEqual(r.setActive(false), [E(.left, phase: .released), E(.activate, phase: .released)])
        XCTAssertEqual(r.tick(at: 10), [])
        XCTAssertEqual(r.setActive(false), [])
        r.setActive(true)
        XCTAssertEqual(r.receive([.activate], from: .keyboard, at: 11), [])
        _ = r.receive(Set<A>(), from: .keyboard, at: 12)
        XCTAssertEqual(r.receive([.activate], from: .keyboard, at: 13), [E(.activate, phase: .pressed)])
        XCTAssertEqual(r.reset(), [E(.activate, phase: .released)])
        XCTAssertEqual(r.sourceCount, 0)
        XCTAssertEqual(r.receive([.activate], from: .keyboard, at: 14), [])
    }
    func testTwoSourcesCannotReleaseEachOthersActions() {
        var r = started(); let other = Switch2ActionSource.external(UUID())
        _ = r.receive(Set<A>(), from: .keyboard, at: 0)
        _ = r.receive(Set<A>(), from: other, at: 0)
        XCTAssertEqual(r.receive([.right], from: .keyboard, at: 1), [E(.right, phase: .pressed)])
        XCTAssertEqual(r.receive([.right], from: other, at: 2), [])
        XCTAssertEqual(r.remove(.keyboard), [])
        XCTAssertEqual(r.tick(at: 3), [E(.right, phase: .repeated)])
        XCTAssertEqual(r.remove(other), [E(.right, phase: .released)])
        XCTAssertEqual(r.tick(at: 4), [])
    }
    func testOpposingDirectionsAndRemovalNeverManufacturePresses() {
        var r = started(); let other = Switch2ActionSource.external(UUID())
        _ = r.receive(Set<A>(), from: .keyboard, at: 0)
        _ = r.receive(Set<A>(), from: other, at: 0)
        _ = r.receive([.left], from: .keyboard, at: 1)
        XCTAssertEqual(r.receive([.right], from: other, at: 2), [E(.left, phase: .released)])
        XCTAssertEqual(r.remove(.keyboard), [])
        XCTAssertEqual(r.tick(at: 3), [])
        _ = r.receive(Set<A>(), from: other, at: 4)
        XCTAssertEqual(r.receive([.up, .down, .left, .right], from: other, at: 5), [])
    }
    func testCustomBindingsAndAliasedButtonsShareOneAction() throws {
        enum Command: Hashable, Sendable { case save, delete }
        var r = try Switch2ActionRouter(actions: [Command.save], bindings: [
            .init(.save, from: .buttons(.a)), .init(.save, from: .buttons(.b))])
        r.setActive(true); _ = r.receive(state(), from: .keyboard, at: 0)
        XCTAssertEqual(r.receive(state(.a), from: .keyboard, at: 1), [.init(.save, phase: .pressed)])
        XCTAssertEqual(r.receive(state([.a, .b]), from: .keyboard, at: 2), [])
        XCTAssertEqual(r.receive(state(.b), from: .keyboard, at: 3), [])
        XCTAssertEqual(r.receive(state(), from: .keyboard, at: 4), [.init(.save, phase: .released)])
        XCTAssertEqual(r.receive([.delete], from: .keyboard, at: 5), [])
    }
    func testDigitalChordsRequireAllBitsAndNeutralBeforeArming() throws {
        var r = try R(actions: [.activate], bindings: [.init(.activate, from: .buttons([.a, .b]))])
        r.setActive(true)
        XCTAssertEqual(r.receive(state(.a), from: .keyboard, at: 0), [])
        XCTAssertEqual(r.receive(state([.a, .b]), from: .keyboard, at: 1), [])
        _ = r.receive(state(), from: .keyboard, at: 2)
        XCTAssertEqual(r.receive(state(.a), from: .keyboard, at: 3), [])
        XCTAssertEqual(r.receive(state([.a, .b]), from: .keyboard, at: 4), [E(.activate, phase: .pressed)])
        XCTAssertEqual(r.receive(state(.b), from: .keyboard, at: 5), [E(.activate, phase: .released)])
    }
    func testPrimaryStickFallsBackToRightJoyCon() {
        var r = started()
        _ = r.receive(Switch2ControllerState(), from: .keyboard, at: 0)
        XCTAssertEqual(r.receive(.init(rightStick: .init(x: -1)), from: .keyboard, at: 1), [E(.left, phase: .pressed)])
        XCTAssertEqual(r.receive(.init(leftStick: .init(), rightStick: .init(x: -1)), from: .keyboard, at: 2),
                       [E(.left, phase: .released)])
    }
    func testAnalogTriggerTravelIsIndependentOfClicks() throws {
        var r = try R(actions: [.activate, .back], bindings: [
            .init(.activate, from: .axis(.leftTrigger, positive: true)), .init(.back, from: .buttons(.zl))])
        r.setActive(true); _ = r.receive(state(), from: .keyboard, at: 0)
        XCTAssertEqual(r.receive(.init(buttons: .zl, leftTrigger: .init(isPressed: true)), from: .keyboard, at: 1),
                       [E(.back, phase: .pressed)])
        XCTAssertEqual(r.receive(.init(leftTrigger: .init(travel: 0.8)), from: .keyboard, at: 2),
                       [E(.back, phase: .released), E(.activate, phase: .pressed)])
        XCTAssertEqual(r.receive(.init(leftTrigger: .init(travel: 0.4)), from: .keyboard, at: 3), [])
        XCTAssertEqual(r.receive(.init(leftTrigger: .init(travel: 0.3)), from: .keyboard, at: 4), [E(.activate, phase: .released)])
    }
    func testRebindingIsAtomicAndReleasesOldActions() throws {
        var r = started(); _ = r.receive(state(), from: .keyboard, at: 0)
        _ = r.receive(state(.a), from: .keyboard, at: 1)
        XCTAssertThrowsError(try r.replaceBindings([.init(.back, from: .buttons([]))]))
        XCTAssertEqual(r.heldActions, [.activate])
        XCTAssertEqual(try r.replaceBindings([.init(.back, from: .buttons(.a))]), [E(.activate, phase: .released)])
        XCTAssertEqual(r.receive(state(.a), from: .keyboard, at: 2), [])
        _ = r.receive(state(), from: .keyboard, at: 3)
        XCTAssertEqual(r.receive(state(.a), from: .keyboard, at: 4), [E(.back, phase: .pressed)])
    }
    func testNavigationPresetMapsEveryButtonAndSignedAxis() {
        for (button, action) in [(Switch2Buttons.dpadUp, A.up), (.dpadDown, .down),
            (.dpadLeft, .left), (.dpadRight, .right), (.a, .activate), (.b, .back)] {
            var r = started(); _ = r.receive(state(), from: .keyboard, at: 0)
            XCTAssertEqual(r.receive(state(button), from: .keyboard, at: 1), [E(action, phase: .pressed)])
            XCTAssertEqual(r.receive(state(), from: .keyboard, at: 2), [E(action, phase: .released)])
        }
        for (x, y, action) in [(1.0, 0.0, A.right), (-1, 0, .left), (0, 1, .up), (0, -1, .down)] {
            var r = started(); _ = r.receive(state(), from: .keyboard, at: 0)
            XCTAssertEqual(r.receive(state(x: x, y: y), from: .keyboard, at: 1), [E(action, phase: .pressed)])
        }
    }
    func testControllerMetadataSharesTheSourceAdmissionBound() {
        var r = started()
        let ids = (0..<1_000).map { _ in Switch2ControllerID(rawValue: UUID()) }
        for id in ids {
            _ = r.receive(.input(controller(id, connection: UUID(), sequence: 0)), at: 0)
        }
        XCTAssertEqual(r.sourceCount, 64)
        XCTAssertEqual(r.receive(.snapshot(.init()), at: 1), [])
        XCTAssertEqual(r.sourceCount, 0)
        XCTAssertEqual(r.receive(.input(controller(ids.last!, connection: UUID(), sequence: 1, buttons: .a)), at: 2), [])
        XCTAssertEqual(r.sourceCount, 1)
    }
    func testAdmissionBoundDoesNotEvictExistingOwners() {
        var r = started(); let sources = (0..<65).map { _ in Switch2ActionSource.external(UUID()) }
        for source in sources { _ = r.receive(Set<A>(), from: source, at: 0) }
        XCTAssertEqual(r.sourceCount, 64)
        XCTAssertEqual(r.receive([.activate], from: sources[64], at: 1), [])
        XCTAssertEqual(r.receive([.activate], from: sources[0], at: 2), [E(.activate, phase: .pressed)])
        XCTAssertEqual(r.remove(sources[0]), [E(.activate, phase: .released)])
        _ = r.receive(Set<A>(), from: sources[64], at: 3)
        XCTAssertEqual(r.receive([.activate], from: sources[64], at: 4), [E(.activate, phase: .pressed)])
    }
    func testInvalidOrBackwardClockFailsClosed() {
        for invalid in [Double.nan, .infinity, -.infinity, -1, 0.5, .greatestFiniteMagnitude] {
            var r = started(); _ = r.receive(Set<A>(), from: .keyboard, at: 0)
            _ = r.receive([.up], from: .keyboard, at: 1)
            XCTAssertEqual(r.tick(at: invalid), [E(.up, phase: .released)])
            XCTAssertEqual(r.sourceCount, 0)
            XCTAssertEqual(r.receive([.up], from: .keyboard, at: 2), [])
        }
    }
    func testConfigurationValidation() throws {
        XCTAssertThrowsError(try R(actions: []))
        XCTAssertThrowsError(try R(actions: [.up, .up]))
        XCTAssertThrowsError(try R(actions: [.up], repeating: [.back]))
        XCTAssertThrowsError(try R(actions: [.up], bindings: [.init(.back, from: .buttons(.a))]))
        XCTAssertThrowsError(try R(actions: [.up], opposing: [[.up]]))
        XCTAssertThrowsError(try R(actions: [.up], repeatDelay: .nan))
        XCTAssertThrowsError(try R(actions: [.up], repeatInterval: 0))
        XCTAssertThrowsError(try R(actions: [.up], activationThreshold: 0.3, releaseThreshold: 0.4))
        XCTAssertThrowsError(try R(actions: [.up], releaseThreshold: 0))
        XCTAssertThrowsError(try R(actions: [.up], maximumSources: 65))
        XCTAssertThrowsError(try R(actions: [.up], maximumSources: 0))
        XCTAssertThrowsError(try Switch2ActionRouter(actions: Array(0..<129)))
        XCTAssertThrowsError(try R(actions: [.up], bindings: Array(repeating: .init(.up, from: .buttons(.a)), count: 257)))
        _ = try Switch2ActionRouter(actions: Array(0..<128))
    }
    func testControllerEventsOwnGenerationAndSequenceRecovery() {
        var r = started(); let id = Switch2ControllerID(rawValue: UUID()), generation = UUID(), replacement = UUID()
        func input(_ seq: UInt64, _ buttons: Switch2Buttons = [], _ connection: UUID? = nil) -> Switch2ControllerEvent {
            .input(controller(id, connection: connection ?? generation, sequence: seq, buttons: buttons))
        }
        _ = r.receive(input(1), at: 0)
        XCTAssertEqual(r.receive(input(2, .a), at: 1), [E(.activate, phase: .pressed)])
        XCTAssertEqual(r.receive(input(4, .a), at: 2), [E(.activate, phase: .released)])
        XCTAssertEqual(r.receive(input(5, .a), at: 3), [])
        _ = r.receive(input(6), at: 4)
        XCTAssertEqual(r.receive(input(7, .a), at: 5), [E(.activate, phase: .pressed)])
        XCTAssertEqual(r.receive(input(1, .a, replacement), at: 6), [E(.activate, phase: .released)])
        XCTAssertEqual(r.receive(input(2, .a, replacement), at: 7), [])
        _ = r.receive(input(3, [], replacement), at: 8)
        XCTAssertEqual(r.receive(input(4, .a, replacement), at: 9), [E(.activate, phase: .pressed)])
        XCTAssertEqual(r.receive(.disconnected(id, .linkLost), at: 10), [E(.activate, phase: .released)])
        XCTAssertEqual(r.sourceCount, 0)
    }
    func testConnectedEventResetsAndSequenceWrapRemainsContiguous() {
        var r = started(); let id = Switch2ControllerID(rawValue: UUID()), generation = UUID()
        let neutral = controller(id, connection: generation, sequence: UInt64.max)
        _ = r.receive(.input(neutral), at: 0)
        let pressed = controller(id, connection: generation, sequence: 0, buttons: .a)
        XCTAssertEqual(r.receive(.input(pressed), at: 1), [E(.activate, phase: .pressed)])
        XCTAssertEqual(r.receive(.connected(pressed), at: 2), [E(.activate, phase: .released)])
        XCTAssertEqual(r.receive(.input(pressed), at: 3), [])
    }
    func testOverflowSnapshotResetsControllersButPreservesLocalOwnership() {
        var r = started(); let id = Switch2ControllerID(rawValue: UUID()), generation = UUID()
        _ = r.receive(Set<A>(), from: .keyboard, at: 0)
        _ = r.receive([.up], from: .keyboard, at: 1)
        _ = r.receive(.input(controller(id, connection: generation, sequence: 1)), at: 2)
        let pressed = controller(id, connection: generation, sequence: 2, buttons: .a)
        _ = r.receive(.input(pressed), at: 3)
        XCTAssertEqual(r.receive(.snapshot(.init(controllers: [pressed])), at: 4), [E(.activate, phase: .released)])
        XCTAssertEqual(r.heldActions, [.up]); XCTAssertEqual(r.sourceCount, 1)
        XCTAssertEqual(r.tick(at: 5), [E(.up, phase: .repeated)])
        XCTAssertEqual(r.receive(.input(pressed), at: 6), [])
        _ = r.receive(.input(controller(id, connection: generation, sequence: 3)), at: 7)
        XCTAssertEqual(r.receive(.input(controller(id, connection: generation, sequence: 4, buttons: .a)), at: 8),
                       [E(.activate, phase: .pressed)])
    }
    func testTenThousandReportsPreserveEdgesWithoutGrowingSourceStorage() {
        var r = started(); let id = Switch2ControllerID(rawValue: UUID()), generation = UUID()
        _ = r.receive(.input(controller(id, connection: generation, sequence: 0)), at: 0)
        for seq in 1...10_000 {
            let pressed = seq % 2 == 1
            XCTAssertEqual(r.receive(.input(controller(id, connection: generation, sequence: UInt64(seq), buttons: pressed ? .a : [])),
                                     at: Double(seq)), [E(.activate, phase: pressed ? .pressed : .released)])
        }
        XCTAssertEqual(r.sourceCount, 1); XCTAssertTrue(r.heldActions.isEmpty)
    }
}
