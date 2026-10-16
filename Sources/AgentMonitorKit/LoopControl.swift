import Foundation

struct LoopError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Folder and command permissions of headless `agy` runs, kept in ~/.gemini/antigravity-cli/settings.json.
/// A run that needs anything outside them is refused and stops.
struct AgyPermissions: Equatable {
    static let path = FileManager.default.homeDirectoryForCurrentUser.path + "/.gemini/antigravity-cli/settings.json"

    private(set) var allow: [String]

    var commands: [String] { allow.compactMap { Self.value(of: $0, rule: "command") } }

    func canRead(_ folder: String) -> Bool { covers(folder, rule: "read_file") }
    func canWrite(_ folder: String) -> Bool { covers(folder, rule: "write_file") }

    mutating func setFolder(_ folder: String, allowed: Bool) {
        let rules = ["read_file(\(folder))", "write_file(\(folder))"]
        allow.removeAll { rules.contains($0) }
        if allowed { allow.insert(contentsOf: rules, at: 0) }
    }

    mutating func setCommand(_ command: String, allowed: Bool) {
        let rule = "command(\(command))"
        allow.removeAll { $0 == rule }
        if allowed { allow.append(rule) }
    }

    /// nil when the file exists but cannot be parsed, so it is never overwritten blindly.
    static func load() -> AgyPermissions? {
        guard FileManager.default.fileExists(atPath: path) else { return AgyPermissions(allow: []) }
        guard let settings = readSettings() else { return nil }
        return AgyPermissions(allow: (settings["permissions"] as? [String: Any])?["allow"] as? [String] ?? [])
    }

    /// Replaces only `permissions.allow`, keeps every other setting, and leaves the previous file as settings.json.bak.
    func save() throws {
        let manager = FileManager.default
        var settings: [String: Any] = [:]
        if manager.fileExists(atPath: Self.path) {
            guard let existing = Self.readSettings() else {
                throw LoopError(message: "settings.json agy tidak bisa dibaca, jadi tidak diubah.")
            }
            settings = existing
            let backup = Self.path + ".bak"
            try? manager.removeItem(atPath: backup)
            try manager.copyItem(atPath: Self.path, toPath: backup)
        }
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        permissions["allow"] = allow
        settings["permissions"] = permissions
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let url = URL(fileURLWithPath: Self.path)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// A rule for a folder also covers everything inside it.
    private func covers(_ folder: String, rule: String) -> Bool {
        allow.contains { entry in
            guard let path = Self.value(of: entry, rule: rule) else { return false }
            return folder == path || folder.hasPrefix(path + "/")
        }
    }

    /// `rule(value)` → value.
    private static func value(of entry: String, rule: String) -> String? {
        guard entry.hasPrefix(rule + "("), entry.hasSuffix(")") else { return nil }
        return String(entry.dropFirst(rule.count + 1).dropLast())
    }

    private static func readSettings() -> [String: Any]? {
        FileManager.default.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

/// ~/.aegis-loop/state.json, which Claude and the panel write at every hand-off,
/// plus each project's last state and Gemini conversation so switching projects loses nothing.
enum LoopStore {
    static let stateURL = AegisLoop.directory.appendingPathComponent("state.json")

    static func read() -> LoopState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(LoopState.self, from: data)
    }

    /// Written whole and renamed into place, so nobody reads half a file.
    static func write(_ state: LoopState) throws {
        var state = state
        state.updatedAt = ISODate.string(Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: AegisLoop.directory, withIntermediateDirectories: true)
        try encoder.encode(state).write(to: stateURL, options: .atomic)
        remember(state)
    }

    static func remember(_ state: LoopState) {
        guard let project = state.project, let data = try? JSONEncoder().encode(state) else { return }
        var states = UserDefaults.standard.dictionary(forKey: "loopStates") ?? [:]
        states[project] = data
        UserDefaults.standard.set(states, forKey: "loopStates")
    }

    static func saved(for project: String) -> LoopState? {
        (UserDefaults.standard.dictionary(forKey: "loopStates")?[project] as? Data)
            .flatMap { try? JSONDecoder().decode(LoopState.self, from: $0) }
    }

    static var knownProjects: [String] {
        (UserDefaults.standard.dictionary(forKey: "loopStates")?.keys).map { $0.sorted() } ?? []
    }

    static func conversation(for project: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: "loopConversations") as? [String: String])?[project]
    }

    static func setConversation(_ id: String, for project: String) {
        var conversations = UserDefaults.standard.dictionary(forKey: "loopConversations") as? [String: String] ?? [:]
        guard conversations[project] != id else { return }
        conversations[project] = id
        UserDefaults.standard.set(conversations, forKey: "loopConversations")
    }
}

/// One headless `agy -p` run that the panel starts for the loop. Its stream-json output goes to
/// ~/.aegis-loop/rounds and its prompt to ~/.aegis-loop/prompts, under the same name.
final class LoopRunner {
    struct Request {
        let project: String
        let prompt: String
        let model: String
        let conversation: String?
        let round: Int
    }

    private var process: Process?
    private(set) var stopped = false

    var isRunning: Bool { process?.isRunning == true }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// Starts the run and returns its log path. `ended` is called with that path on a background queue once agy exits.
    func start(_ request: Request, ended: @escaping (String) -> Void) throws -> String {
        let manager = FileManager.default
        let rounds = AegisLoop.directory.appendingPathComponent("rounds")
        let prompts = AegisLoop.directory.appendingPathComponent("prompts")
        try manager.createDirectory(at: rounds, withIntermediateDirectories: true)
        try manager.createDirectory(at: prompts, withIntermediateDirectories: true)

        let folder = Format.folderName(request.project) ?? "loop"
        let name = "\(folder)-r\(String(format: "%02d", request.round))-\(Self.stamp.string(from: Date()))"
        let log = rounds.appendingPathComponent(name + ".jsonl")
        try request.prompt.write(to: prompts.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8)
        manager.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)

        var arguments = ["-p", request.prompt, "--model", request.model, "--mode", "accept-edits",
                         "--add-dir", request.project, "--output-format", "stream-json", "--print-timeout", "60m"]
        if let conversation = request.conversation { arguments += ["--conversation", conversation] }

        let process = Process()
        // A login shell gives agy the PATH of a terminal (go, npm, swift), which an app started from Finder lacks.
        // `exec` replaces the shell, so the process the panel stops is agy itself.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \"$0\" \"$@\"", ModelCatalog.agyPath] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: request.project)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { _ in
            try? output.close()
            ended(log.path)
        }
        try process.run()
        self.process = process
        stopped = false
        return log.path
    }

    func stop() {
        guard isRunning else { return }
        stopped = true
        process?.terminate()
    }
}
