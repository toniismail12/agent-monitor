import Foundation

/// AI apps that expose no session data: only shown while they run, with their CPU and memory.
package final class PresenceProvider: AgentProvider {
    private struct Signature {
        let kind: AgentKind
        let title: String
        let matches: (String) -> Bool
    }

    private static let signatures = [
        Signature(kind: .copilot, title: "Ekstensi VS Code") { $0.contains("@github/copilot") || $0.contains("copilot-language-server") },
        Signature(kind: .claudeDesktop, title: "Aplikasi desktop") { $0.hasPrefix("/Applications/Claude.app/") },
        Signature(kind: .chatGPT, title: "Aplikasi desktop") { $0.hasPrefix("/Applications/ChatGPT.app/") },
        Signature(kind: .ollama, title: "Server model lokal") { $0 == "ollama" || $0.hasSuffix("/ollama") },
    ]

    package var ollamaModels: String?

    package init(ollamaModels: String? = nil) {
        self.ollamaModels = ollamaModels
    }

    package func poll(_ context: PollContext) -> [AgentSession] {
        let processes = context.processes
        return Self.signatures.compactMap { signature in
            let matched = processes.filter { signature.matches($0.path) }
            guard !matched.isEmpty else { return nil }
            let detail = signature.kind == .ollama ? (ollamaModels ?? "Server berjalan") : "Berjalan"
            return AgentSession(
                id: "app:\(signature.kind.rawValue)", kind: signature.kind, title: signature.title,
                state: .running, detail: detail,
                cpu: matched.reduce(0) { $0 + $1.cpu }, memoryMB: matched.reduce(0) { $0 + $1.memoryMB })
        }
    }

    private static let ollamaSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.0
        config.timeoutIntervalForResource = 1.0
        return URLSession(configuration: config)
    }()

    /// Fetches currently loaded models from Ollama's local HTTP API via URLSession.
    package static func fetchOllamaModels() async -> String? {
        guard let url = URL(string: "http://127.0.0.1:11434/api/ps") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        guard let (data, response) = try? await ollamaSession.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseOllamaModels(data)
    }

    /// Pure function to parse JSON response from Ollama's /api/ps endpoint.
    package static func parseOllamaModels(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return nil }
        let names = models.compactMap { $0["name"] as? String }
        return names.isEmpty ? "Tidak ada model dimuat" : "Model aktif: " + names.joined(separator: ", ")
    }
}
