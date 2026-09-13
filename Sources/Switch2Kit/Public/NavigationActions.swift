/// Optional navigation vocabulary. Custom hosts can instead use their own Hashable, Sendable enum.
public enum Switch2NavigationAction: String, CaseIterable, Hashable, Sendable {
    case up, down, left, right, activate, back
    public var isDirectional: Bool { self != .activate && self != .back }
}

extension Switch2ActionRouter where Action == Switch2NavigationAction {
    /// D-pad and primary stick navigation with A=activate, B=back. Directional actions repeat;
    /// activate/back are edge-only. The primary stick is left when present, otherwise right.
    /// This is an optional preset, not a change to raw controller values or global input behavior.
    public static func navigation() -> Self {
        // All arguments are fixed, valid library constants, not host-provided configuration.
        try! Self(actions: Switch2NavigationAction.allCases, bindings: [
            .init(.up, from: .buttons(.dpadUp)), .init(.down, from: .buttons(.dpadDown)),
            .init(.left, from: .buttons(.dpadLeft)), .init(.right, from: .buttons(.dpadRight)),
            .init(.activate, from: .buttons(.a)), .init(.back, from: .buttons(.b)),
            .init(.up, from: .axis(.primaryY, positive: true)),
            .init(.down, from: .axis(.primaryY, positive: false)),
            .init(.left, from: .axis(.primaryX, positive: false)),
            .init(.right, from: .axis(.primaryX, positive: true))
        ], repeating: [.up, .down, .left, .right], opposing: [[.up, .down], [.left, .right]])
    }
}
