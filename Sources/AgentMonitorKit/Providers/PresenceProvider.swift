import Foundation

/// AI apps that expose no session data: only shown while they run, with their CPU and memory.
enum PresenceProvider {
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

    static func poll(processes: [ProcessEntry]) -> [AgentSession] {
        signatures.compactMap { signature in
            let matched = processes.filter { signature.matches($0.path) }
            guard !matched.isEmpty else { return nil }
            let detail = signature.kind == .ollama ? (ollamaModels() ?? "Server berjalan") : "Berjalan"
            return AgentSession(
                id: "app:\(signature.kind.rawValue)", kind: signature.kind, title: signature.title,
                state: .running, detail: detail,
                cpu: matched.reduce(0) { $0 + $1.cpu }, memoryMB: matched.reduce(0) { $0 + $1.memoryMB })
        }
    }

    /// Models Ollama currently holds in memory, from its local API.
    private static func ollamaModels() -> String? {
        guard let output = Shell.run("/usr/bin/curl", ["-s", "--max-time", "1", "http://127.0.0.1:11434/api/ps"]),
              let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return nil }
        let names = models.compactMap { $0["name"] as? String }
        return names.isEmpty ? "Tidak ada model dimuat" : "Model aktif: " + names.joined(separator: ", ")
    }
}
