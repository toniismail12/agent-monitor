import Foundation

/// Claude Code sessions, read from the transcripts in ~/.claude/projects/<project>/<session>.jsonl.
package final class ClaudeCodeProvider: AgentProvider {
    /// Sessions whose transcript has not changed for this long are no longer shown.
    package static let window: TimeInterval = 30 * 60

    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private var transcripts: [String: ClaudeTranscript] = [:]
    private var recent: [String: Date] = [:]
    private var lastScan = Date.distantPast

    package func poll(_ context: PollContext) -> [AgentSession] {
        let now = context.now
        let processes = context.processes
        if now.timeIntervalSince(lastScan) >= 5 {
            recent = FileScan.recentFiles(in: FileScan.subdirectories(of: root), ext: "jsonl", within: Self.window, now: now)
            transcripts = transcripts.filter { recent[$0.key] != nil }
            lastScan = now
        }

        var sessions = recent.compactMap { path, scanned -> AgentSession? in
            let transcript = transcripts[path] ?? ClaudeTranscript(path: path)
            transcripts[path] = transcript
            transcript.update()
            return transcript.session(now: now, modified: FileScan.modificationDate(path) ?? scanned)
        }

        if sessions.isEmpty {
            let running = processes.filter { $0.path.contains("anthropic.claude-code") || $0.path.hasSuffix("/claude") }
            if !running.isEmpty {
                sessions.append(AgentSession(
                    id: "claude:process", kind: .claudeCode, title: "Claude Code siap", state: .running,
                    detail: "Siap, belum ada sesi dalam 30 menit terakhir",
                    cpu: running.reduce(0) { $0 + $1.cpu }, memoryMB: running.reduce(0) { $0 + $1.memoryMB }))
            }
        }
        return sessions
    }
}

package final class ClaudeTranscript {
    private enum Last {
        case none, prompt, thinking, toolUse, turnEnded
    }

    package let path: String
    package let sessionId: String
    private let tail: JSONLTail
    private var title: String?
    private var cwd: String?
    private var cost: Double?
    private var model: String?
    private var last: Last = .none
    private var lastText = ""
    private var lastEntryAt: Date?
    private let activityLog = TranscriptActivityLog()

    package init(path: String) {
        self.path = path
        sessionId = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        tail = JSONLTail(path: path)
        cwd = Self.startingDirectory(of: path)
    }

    /// The tail window can start mid-session, after a `cd`; the first entries hold the project folder.
    private static func startingDirectory(of path: String) -> String? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        for line in file.readData(ofLength: 256 * 1024).split(separator: 0x0A) {
            if let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let directory = entry["cwd"] as? String {
                return directory
            }
        }
        return nil
    }

    package func update() {
        // Request blobs and file snapshots are large and carry nothing the panel shows.
        for line in tail.readNewLines()
        where !JSONLTail.hasType(line, in: ["api-request-blob", "api-request-shape", "file-history"]) {
            handle(line)
        }
    }

    /// Nil once the session has been quiet longer than the provider window; the file itself may be touched later.
    package func session(now: Date, modified: Date) -> AgentSession? {
        let lastAt = lastEntryAt ?? modified
        let age = now.timeIntervalSince(lastAt)
        guard age < ClaudeCodeProvider.window else { return nil }

        // Parallel tool calls finish one by one, so an unfinished one says more than the latest entry.
        let running = activityLog.runningActivity
        let state: AgentState
        let detail: String
        switch last {
        case .turnEnded:
            state = .waiting
            detail = Format.snippet(lastText)
        case .none:
            state = .idle
            detail = ""
        case .prompt, .thinking, .toolUse:
            state = age < 600 ? .working : .idle
            if let running {
                let elapsed = now.timeIntervalSince(running.startedAt)
                detail = elapsed > 20
                    ? "\(running.title) (\(Format.duration(elapsed))) · mungkin menunggu izin"
                    : "\(running.title) \(Format.snippet(running.detail, limit: 80))"
            } else {
                detail = "Berpikir…"
            }
        }

        let shown = activityLog.visibleActivities(for: state)
        return AgentSession(
            id: "claude:\(sessionId)", kind: .claudeCode,
            title: title ?? Format.folderName(cwd) ?? String(sessionId.prefix(8)),
            project: cwd, state: state, detail: detail, lastActivity: lastAt,
            costUSD: cost, model: model, activities: shown, logPath: path)
    }

    private func handle(_ line: Data) {
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = entry["type"] as? String else { return }
        // The first cwd is the project; later ones follow `cd` into temporary folders.
        if cwd == nil, let directory = entry["cwd"] as? String { cwd = directory }
        let time = ISODate.parse(entry["timestamp"] as? String)

        switch type {
        case "ai-title":
            title = entry["aiTitle"] as? String
        case "cost-state":
            if let usd = entry["totalCostUSD"] as? Double { cost = usd }
        case "api-request":
            mark(.thinking, at: time)
        case "user":
            if entry["isMeta"] as? Bool != true { handleUser(entry, at: time) }
        case "assistant":
            handleAssistant(entry, at: time)
        default:
            break
        }
    }

    private func handleUser(_ entry: [String: Any], at time: Date?) {
        let content = (entry["message"] as? [String: Any])?["content"]
        if let text = content as? String {
            activityLog.append(.prompt, "Prompt", text, active: false, at: time)
            mark(.prompt, at: time)
            return
        }
        guard let blocks = content as? [[String: Any]] else { return }
        let results = blocks.filter { $0["type"] as? String == "tool_result" }
        if !results.isEmpty {
            for result in results {
                if let id = result["tool_use_id"] as? String { activityLog.closeTool(id, at: time) }
            }
            mark(.thinking, at: time)
        } else if let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String {
            activityLog.append(.prompt, "Prompt", text, active: false, at: time)
            mark(.prompt, at: time)
        }
    }

    /// Each block is written once its message is complete, carrying that message's final stop_reason.
    private func handleAssistant(_ entry: [String: Any], at time: Date?) {
        guard let message = entry["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return }
        let endsTurn = (message["stop_reason"] as? String).map { $0 != "tool_use" } ?? false
        if let name = message["model"] as? String, !name.hasPrefix("<") { model = name }

        for block in blocks {
            switch block["type"] as? String {
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                let (kind, label) = Activity.describe(claudeTool: name)
                let useId = block["id"] as? String
                activityLog.append(kind, label, Activity.summary(of: block["input"] as? [String: Any] ?? [:]),
                                   active: true, at: time, toolId: useId)
                mark(.toolUse, at: time)
            case "text":
                lastText = block["text"] as? String ?? ""
                activityLog.append(.response, "Menulis jawaban", lastText, active: false, at: time)
                mark(endsTurn ? .turnEnded : .thinking, at: time)
            case "thinking", "redacted_thinking":
                mark(endsTurn ? .turnEnded : .thinking, at: time)
            default:
                break
            }
        }
    }

    private func mark(_ state: Last, at time: Date?) {
        last = state
        if let time { lastEntryAt = time }
    }
}
