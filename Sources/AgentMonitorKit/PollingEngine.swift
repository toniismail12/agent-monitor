import Foundation

/// Result of a polling pass by PollingEngine.
package struct PollResult: Sendable {
    package let sessions: [AgentSession]
    package let loop: LoopSnapshot?
    package let loopConversationId: String?
    package let loopOutcome: (status: String, error: String?)?

    package init(
        sessions: [AgentSession],
        loop: LoopSnapshot? = nil,
        loopConversationId: String? = nil,
        loopOutcome: (status: String, error: String?)? = nil
    ) {
        self.sessions = sessions
        self.loop = loop
        self.loopConversationId = loopConversationId
        self.loopOutcome = loopOutcome
    }
}

/// Actor that coordinates background polling across all agent providers and loop state.
package actor PollingEngine {
    private let processSource: @Sendable () -> [ProcessEntry]
    private let providers: [any AgentProvider]
    private let gemini: GeminiProvider?
    private let presence: PresenceProvider?
    private let aegis: AegisLoop

    private var isFetchingOllama = false
    private var lastOllamaFetch = Date.distantPast
    private var lastProcesses: [ProcessEntry] = []
    private var lastProcessesAt = Date.distantPast

    package init(
        providers: [any AgentProvider]? = nil,
        processSource: @escaping @Sendable () -> [ProcessEntry] = { ProcessSnapshot.capture() },
        aegis: AegisLoop = AegisLoop()
    ) {
        self.processSource = processSource
        self.aegis = aegis
        if let providers {
            self.providers = providers
            self.gemini = providers.compactMap { $0 as? GeminiProvider }.first
            self.presence = providers.compactMap { $0 as? PresenceProvider }.first
        } else {
            let gemini = GeminiProvider()
            let presence = PresenceProvider()
            self.gemini = gemini
            self.presence = presence
            self.providers = [ClaudeCodeProvider(), CodexProvider(), gemini, presence]
        }
    }

    /// In --dump mode, fetches Ollama models first if Ollama is running, so the snapshot has current models.
    package func prepareOllama() async {
        let processes = processSource()
        lastProcesses = processes
        lastProcessesAt = Date()
        guard presence != nil && processes.contains(where: { $0.path == "ollama" || $0.path.hasSuffix("/ollama") }) else { return }
        let models = await PresenceProvider.fetchOllamaModels()
        storeOllamaModels(models)
        lastOllamaFetch = Date()
    }

    /// Performs a single polling pass across all providers.
    /// When triggered by a file event, reuses the process snapshot if it is less than 5 seconds old.
    package func poll(now: Date = Date(), fromFileEvent: Bool = false) -> PollResult {
        let processes: [ProcessEntry]
        let age = now.timeIntervalSince(lastProcessesAt)
        if fromFileEvent && age >= 0 && age < 5 && !lastProcesses.isEmpty {
            processes = lastProcesses
        } else {
            processes = processSource()
            lastProcesses = processes
            lastProcessesAt = now
        }
        let snapshot = aegis.refresh()

        if presence != nil && processes.contains(where: { $0.path == "ollama" || $0.path.hasSuffix("/ollama") }) {
            fetchOllamaSeparately()
        }

        let context = PollContext(now: now, processes: processes, loop: snapshot?.state)
        var sessions: [AgentSession] = []
        for provider in providers {
            sessions += provider.poll(context)
        }
        // What needs the user first, then the most recently active.
        sessions.sort {
            ($0.state, $1.lastActivity ?? .distantPast) < ($1.state, $0.lastActivity ?? .distantPast)
        }

        return PollResult(
            sessions: sessions,
            loop: snapshot,
            loopConversationId: gemini?.loopConversationId,
            loopOutcome: gemini?.loopOutcome
        )
    }

    private func fetchOllamaSeparately() {
        let now = Date()
        guard !isFetchingOllama, now.timeIntervalSince(lastOllamaFetch) >= 5 else { return }
        lastOllamaFetch = now
        isFetchingOllama = true
        Task { [weak self] in
            let models = await PresenceProvider.fetchOllamaModels()
            await self?.storeOllamaModels(models)
        }
    }

    private func storeOllamaModels(_ models: String?) {
        self.presence?.ollamaModels = models
        self.isFetchingOllama = false
    }
}
