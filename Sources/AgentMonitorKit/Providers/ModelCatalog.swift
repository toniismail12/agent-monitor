import Foundation

/// Which model each agent on this Mac is set to use and which ones it offers, from the agents' own settings and caches.
final class ModelCatalog {
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// Parsed files, kept until the file changes.
    private var cache: [String: (modified: Date, value: Any)] = [:]
    /// `agy models` asks Google, so its answer ("id\tname" lines) is kept between launches.
    private(set) var agyModels: [String]
    private(set) var agyFetchedAt: Date?

    static let agyPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.gemini/bin/agy"

    init() {
        agyModels = UserDefaults.standard.stringArray(forKey: "agyModels") ?? []
        agyFetchedAt = UserDefaults.standard.object(forKey: "agyModelsAt") as? Date
    }

    var agyStale: Bool { agyFetchedAt.map { Date().timeIntervalSince($0) > 12 * 3600 } ?? true }

    /// Slow (it goes over the network), so run it off the main thread.
    static func fetchAgyModels() -> [String]? {
        let output = Shell.run(agyPath, ["models"], timeout: 30) ?? ""
        let lines = output.split(separator: "\n").filter { $0.split(separator: "\t").count == 2 }.map(String.init)
        return lines.isEmpty ? nil : lines
    }

    func storeAgyModels(_ lines: [String], at date: Date) {
        agyModels = lines
        agyFetchedAt = date
        UserDefaults.standard.set(lines, forKey: "agyModels")
        UserDefaults.standard.set(date, forKey: "agyModelsAt")
    }

    func snapshot(sessions: [AgentSession]) -> [AgentModels] {
        var result: [AgentModels] = []
        if AgentKind.claudeCode.isInstalled { result.append(claude(sessions)) }
        if AgentKind.codex.isInstalled { result.append(codex(sessions)) }
        if AgentKind.geminiCLI.isInstalled { result.append(gemini(sessions)) }
        if let ollama = ollama() { result.append(ollama) }
        return result
    }

    // MARK: - Agents

    private func claude(_ sessions: [AgentSession]) -> AgentModels {
        let settings = json(home + "/.claude/settings.json") as? [String: Any]
        let modelSettings = settings?["modelSettings"] as? [String: [String: Any]] ?? [:]
        let catalogFile = FileScan.subdirectories(of: URL(fileURLWithPath: home + "/.claude/cache/model-catalog"))
            .first { $0.pathExtension == "json" }
        let catalog = catalogFile.flatMap { json($0.path) } as? [String: Any]
        let models = ((catalog?["catalog"] as? [String: Any])?["config"] as? [String: Any])?["models"] as? [[String: Any]] ?? []
        let names = Dictionary(models.compactMap { model in
            (model["id"] as? String).map { ($0, model["name"] as? String ?? $0) }
        }, uniquingKeysWith: { first, _ in first })

        return AgentModels(
            kind: .claudeCode, title: AgentKind.claudeCode.name,
            configured: (settings?["model"] as? String).map { "\($0) (settings.json)" },
            inUse: inUse(sessions, kind: .claudeCode) { id in
                let effort = modelSettings[id]?["effortLevel"] as? String
                return (names[id] ?? id) + (effort.map { " · effort \($0)" } ?? "")
            },
            available: models.filter { $0["section"] as? String == "main" }.compactMap { $0["name"] as? String })
    }

    private func codex(_ sessions: [AgentSession]) -> AgentModels {
        let cache = json(home + "/.codex/models_cache.json") as? [String: Any]
        let models = cache?["models"] as? [[String: Any]] ?? []
        let names = Dictionary(models.compactMap { model in
            (model["slug"] as? String).map { ($0, model["display_name"] as? String ?? $0) }
        }, uniquingKeysWith: { first, _ in first })

        let config = topLevelTOML(home + "/.codex/config.toml")
        let configured = config["model"].map { model in
            (names[model] ?? model) + (config["model_reasoning_effort"].map { " · effort \($0)" } ?? "")
        }
        return AgentModels(
            kind: .codex, title: AgentKind.codex.name,
            configured: configured.map { "\($0) (config.toml)" },
            inUse: inUse(sessions, kind: .codex) { names[$0] ?? $0 },
            available: models.filter { $0["visibility"] as? String == "list" }.compactMap { $0["display_name"] as? String })
    }

    private func gemini(_ sessions: [AgentSession]) -> AgentModels {
        let pairs = agyModels.map { $0.split(separator: "\t", maxSplits: 1).map(String.init) }
        let names = Dictionary(pairs.map { ($0[0], $0[1]) }, uniquingKeysWith: { first, _ in first })
        // "Gemini 4 Argon (Low)", "(Medium)" and "(High)" are one model at three effort levels.
        var families: [String] = []
        for pair in pairs {
            let family = pair[1].replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression)
            if !families.contains(family) { families.append(family) }
        }
        return AgentModels(
            kind: .geminiCLI, title: "Gemini CLI (agy)", configured: nil,
            inUse: inUse(sessions, kind: .geminiCLI) { names[$0] ?? $0 },
            available: families)
    }

    /// Models pulled into ~/.ollama: manifests/<registry>/<namespace>/<model>/<tag>.
    private func ollama() -> AgentModels? {
        guard AgentKind.ollama.isInstalled else { return nil }
        let root = URL(fileURLWithPath: home + "/.ollama/models/manifests")
        var names: [String] = []
        for registry in FileScan.subdirectories(of: root) {
            for namespace in FileScan.subdirectories(of: registry) {
                for model in FileScan.subdirectories(of: namespace) {
                    for tag in FileScan.subdirectories(of: model) {
                        let name = "\(model.lastPathComponent):\(tag.lastPathComponent)"
                        names.append(namespace.lastPathComponent == "library" ? name : "\(namespace.lastPathComponent)/\(name)")
                    }
                }
            }
        }
        return AgentModels(kind: .ollama, title: AgentKind.ollama.name, configured: nil, available: names.sorted())
    }

    // MARK: - Helpers

    /// Models the agent's current sessions use, each with the sessions using it.
    private func inUse(_ sessions: [AgentSession], kind: AgentKind, label: (String) -> String) -> [AgentModels.InUse] {
        var order: [String] = []
        var titles: [String: [String]] = [:]
        for session in sessions where session.kind == kind {
            guard let model = session.model else { continue }
            if titles[model] == nil { order.append(model) }
            titles[model, default: []].append(session.title)
        }
        return order.map { AgentModels.InUse(model: label($0), sessions: titles[$0] ?? []) }
    }

    private func json(_ path: String) -> Any? {
        cached(path) { try? JSONSerialization.jsonObject(with: $0) }
    }

    /// `key = "value"` lines before the first `[table]`.
    private func topLevelTOML(_ path: String) -> [String: String] {
        cached(path) { data in
            var values: [String: String] = [:]
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("[") { break }
                let parts = text.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, !parts[0].hasPrefix("#") else { continue }
                values[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            return values
        } as? [String: String] ?? [:]
    }

    private func cached(_ path: String, parse: (Data) -> Any?) -> Any? {
        guard let modified = FileScan.modificationDate(path) else { return nil }
        if let hit = cache[path], hit.modified == modified { return hit.value }
        guard let data = FileManager.default.contents(atPath: path), let value = parse(data) else { return nil }
        cache[path] = (modified, value)
        return value
    }
}
