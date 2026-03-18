import Foundation

public actor AuthStateManager {
    private var currentState: AuthState = .unknown
    private var continuations: [UUID: AsyncStream<AuthState>.Continuation] = [:]

    public var state: AuthState {
        currentState
    }

    public func transition(to newState: AuthState) {
        currentState = newState
        for (_, continuation) in continuations {
            continuation.yield(newState)
        }
    }

    public func stream() -> AsyncStream<AuthState> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(currentState)
            self.continuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeContinuation(id: id) }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
