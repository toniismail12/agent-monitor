import Foundation

/// Codex sessions, read from ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl.
final class CodexProvider {
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    private var transcripts: [String: CodexTranscript] = [:]
    private var recent: [String: Date] = [:]
    private var lastScan = Date.distantPast

    private static let dayPath: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    func poll(now: Date, processes: [ProcessEntry]) -> [AgentSession] {
        if now.timeIntervalSince(lastScan) >= 5 {
            let days = [now, now.addingTimeInterval(-86_400)].map { root.appendingPathComponent(Self.dayPath.string(from: $0)) }
            recent = FileScan.recentFiles(in: days, ext: "jsonl", within: ClaudeCodeProvider.window, now: now)
            transcripts = transcripts.filter { recent[$0.key] != nil }
            lastScan = now
        }

        var sessions = recent.compactMap { path, scanned -> AgentSession? in
            let transcript = transcripts[path] ?? CodexTranscript(path: path)
            transcripts[path] = transcript
            transcript.update()
            return transcript.session(now: now, modified: FileScan.modificationDate(path) ?? scanned)
        }

        if sessions.isEmpty {
            let running = processes.filter { $0.path.hasSuffix("/codex") }
            if !running.isEmpty {
                sessions.append(AgentSession(
                    id: "codex:process", kind: .codex,
                    title: running.contains { $0.path.contains("/.vscode/") } ? "Ekstensi VS Code" : "Codex siap",
                    state: .running,
                    detail: "Siap, belum ada sesi dalam 30 menit terakhir",
                    cpu: running.reduce(0) { $0 + $1.cpu }, memoryMB: running.reduce(0) { $0 + $1.memoryMB }))
            }
        }
        return sessions
    }
}

package final class CodexTranscript {
    private enum Last {
        case none, working, toolCall(String), complete(error: String?)
    }

    package let path: String
    private let tail: JSONLTail
    private var sessionId: String
    private var cwd: String?
    private var tokens: Int?
    private var model: String?
    private var last: Last = .none
    private var lastText = ""
    private var lastEntryAt: Date?
    private var activities: [Activity] = []
    private var nextId = 0
    private var openCalls: [String: Int] = [:]

    package init(path: String) {
        self.path = path
        sessionId = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        tail = JSONLTail(path: path)
    }

    package func update() {
        for line in tail.readNewLines() { handle(line) }
    }

    /// Nil once the session has been quiet longer than the provider window.
    package func session(now: Date, modified: Date) -> AgentSession? {
        let lastAt = lastEntryAt ?? modified
        let age = now.timeIntervalSince(lastAt)
        guard age < ClaudeCodeProvider.window else { return nil }
        let state: AgentState
        let detail: String
        switch last {
        case .complete(let error?):
            state = .failed
            detail = Format.snippet(error)
        case .complete(nil):
            state = .waiting
            detail = Format.snippet(lastText)
        case .toolCall(let name):
            state = age < 600 ? .working : .idle
            detail = "Menjalankan \(name)"
        case .working:
            state = age < 600 ? .working : .idle
            detail = lastText.isEmpty ? "Berpikir…" : Format.snippet(lastText)
        case .none:
            state = .idle
            detail = ""
        }
        var shown = Array(activities.suffix(30).reversed())
        if state != .working {
            for index in shown.indices { shown[index].active = false }
        }
        return AgentSession(
            id: "codex:\(sessionId)", kind: .codex, title: Format.folderName(cwd) ?? "Codex",
            project: cwd, state: state, detail: detail, lastActivity: lastAt,
            tokens: tokens, model: model, activities: shown, logPath: path)
    }

    private func handle(_ line: Data) {
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = entry["type"] as? String else { return }
        let payload = entry["payload"] as? [String: Any] ?? [:]
        let time = ISODate.parse(entry["timestamp"] as? String)

        switch type {
        case "session_meta", "turn_context":
            if cwd == nil, let directory = payload["cwd"] as? String { cwd = directory }
            if let name = payload["model"] as? String { model = name }
        case "event_msg":
            handleEvent(payload, at: time)
        case "response_item":
            handleItem(payload, at: time)
        default:
            break
        }
    }

    private func handleEvent(_ payload: [String: Any], at time: Date?) {
        switch payload["type"] as? String {
        case "task_started", "user_message":
            if let text = payload["message"] as? String { append(.prompt, "Prompt", text, active: false, at: time) }
            mark(.working, at: time)
        case "token_count":
            let usage = (payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any]
            if let total = usage?["total_tokens"] as? Int { tokens = total }
        case "agent_message":
            if let text = payload["message"] as? String { lastText = text }
        case "task_complete":
            if let text = payload["last_agent_message"] as? String { lastText = text }
            let error = (payload["error"] as? [String: Any])?["message"] as? String
            mark(.complete(error: error), at: time)
        default:
            break
        }
    }

    private func handleItem(_ payload: [String: Any], at time: Date?) {
        switch payload["type"] as? String {
        case "custom_tool_call", "function_call":
            let name = payload["name"] as? String ?? "tool"
            let input = payload["input"] as? String ?? payload["arguments"] as? String ?? ""
            let id = append(.command, "Menjalankan", Self.commandSummary(input), active: true, at: time)
            if let callId = payload["call_id"] as? String { openCalls[callId] = id }
            mark(.toolCall(name), at: time)
        case "custom_tool_call_output", "function_call_output":
            if let callId = payload["call_id"] as? String { closeCall(callId, at: time) }
            mark(.working, at: time)
        case "message":
            guard payload["role"] as? String == "assistant",
                  let blocks = payload["content"] as? [[String: Any]] else { return }
            let text = blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
            if !text.isEmpty {
                lastText = text
                append(.response, "Menulis jawaban", text, active: false, at: time)
            }
        case "reasoning":
            mark(.working, at: time)
        default:
            break
        }
    }

    /// Pulls the shell command out of a tool call's input when there is one.
    private static func commandSummary(_ input: String) -> String {
        let pattern = #""(?:cmd|command)"\s*:\s*(?:\[\s*)?"((?:[^"\\]|\\.)*)""#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
           let range = Range(match.range(at: 1), in: input) {
            return String(input[range]).replacingOccurrences(of: "\\\"", with: "\"")
        }
        return input
    }

    private func mark(_ state: Last, at time: Date?) {
        last = state
        if let time { lastEntryAt = time }
    }

    @discardableResult
    private func append(_ kind: Activity.Kind, _ title: String, _ detail: String, active: Bool, at time: Date?) -> Int {
        nextId += 1
        activities.append(Activity(id: nextId, kind: kind, title: title, detail: Format.snippet(detail, limit: 300),
                                   active: active, startedAt: time ?? Date()))
        if activities.count > 80 { activities.removeFirst(activities.count - 80) }
        return nextId
    }

    private func closeCall(_ callId: String, at time: Date?) {
        guard let id = openCalls.removeValue(forKey: callId),
              let index = activities.firstIndex(where: { $0.id == id }) else { return }
        activities[index].active = false
        if let time { activities[index].duration = time.timeIntervalSince(activities[index].startedAt) }
    }
}
