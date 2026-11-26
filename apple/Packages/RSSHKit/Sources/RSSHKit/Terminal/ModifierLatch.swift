/// Sticky modifiers for a touch keyboard: tap Ctrl once and it applies to the next key only; tap it again and it
/// stays on until a third tap. Immutable: every change returns a new latch.
public struct ModifierLatch: Hashable, Sendable {
    public enum State: Hashable, Sendable { case off, once, locked }

    private var states: [Int: State] = [:]   // keyed by KeyModifiers.rawValue of a single modifier

    public init() {}

    public func state(of modifier: KeyModifiers) -> State { states[modifier.rawValue] ?? .off }

    /// The modifiers that apply to the next key.
    public var active: KeyModifiers {
        states.reduce(into: KeyModifiers()) { set, entry in
            if entry.value != .off { set.insert(KeyModifiers(rawValue: entry.key)) }
        }
    }

    /// off -> once -> locked -> off.
    public func tapped(_ modifier: KeyModifiers) -> ModifierLatch {
        let next: State
        switch state(of: modifier) {
        case .off: next = .once
        case .once: next = .locked
        case .locked: next = .off
        }
        return with(modifier, next)
    }

    /// After a key was sent: one-shot modifiers release, locked ones stay.
    public func consumed() -> ModifierLatch {
        var copy = ModifierLatch()
        copy.states = states.filter { $0.value == .locked }
        return copy
    }

    public func cleared() -> ModifierLatch { ModifierLatch() }

    private func with(_ modifier: KeyModifiers, _ state: State) -> ModifierLatch {
        var copy = self
        copy.states[modifier.rawValue] = state == .off ? nil : state
        return copy
    }
}
