import Foundation

/// The answer to one confirm prompt.
public enum AgentDecision: Sendable, Equatable {
    case allowOnce
    case allowForSession
    case deny
}

/// Decides each sign request of one session: no prompt when asking is off, no prompt again for a key allowed for
/// the session, otherwise the prompt; no answer within `timeout` denies. The prompt must end when its task is
/// cancelled (the timeout cancels it).
public actor AgentApprovalGate {
    public static let defaultTimeout: Duration = .seconds(30)

    public typealias Prompt = @Sendable (AgentSignRequest) async -> AgentDecision

    private let askBeforeUse: Bool
    private let timeout: Duration
    private let prompt: Prompt
    private var allowedForSession: Set<UUID> = []

    public init(askBeforeUse: Bool, timeout: Duration = AgentApprovalGate.defaultTimeout, prompt: @escaping Prompt) {
        self.askBeforeUse = askBeforeUse
        self.timeout = timeout
        self.prompt = prompt
    }

    public func approve(_ request: AgentSignRequest) async -> Bool {
        guard askBeforeUse, !allowedForSession.contains(request.keyID) else { return true }
        switch await decision(for: request) {
        case .allowOnce:
            return true
        case .allowForSession:
            allowedForSession.insert(request.keyID)
            return true
        case .deny:
            return false
        }
    }

    private func decision(for request: AgentSignRequest) async -> AgentDecision {
        let (prompt, timeout) = (self.prompt, self.timeout)
        return await withTaskGroup(of: AgentDecision.self) { group in
            group.addTask { await prompt(request) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .deny
            }
            let first = await group.next() ?? .deny
            group.cancelAll()
            return first
        }
    }
}
