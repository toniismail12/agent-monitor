import Foundation

/// Context passed to each provider during a polling pass.
package struct PollContext: Sendable {
    package let now: Date
    package let processes: [ProcessEntry]
    package let loop: LoopState?

    package init(now: Date = Date(), processes: [ProcessEntry] = [], loop: LoopState? = nil) {
        self.now = now
        self.processes = processes
        self.loop = loop
    }
}

/// A provider that detects and polls active sessions for a specific agent or tool family.
package protocol AgentProvider {
    func poll(_ context: PollContext) -> [AgentSession]
}
