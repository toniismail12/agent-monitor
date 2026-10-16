import Foundation

/// Gemini: headless `agy -p` runs (with live activity when the run belongs to the Aegis loop) and the Gemini app.
final class GeminiProvider {
    private let reader = StreamReader()
    /// `agy` arguments never change for a pid, so they are read once; so is the project folder of a run.
    private var argumentsByPid: [Int: String] = [:]
    private var projectByPid: [Int: String] = [:]
    /// How the loop's run ended, once no `agy -p` is running any more.
    private(set) var loopOutcome: (status: String, error: String?)?

    var loopConversationId: String? { reader.conversationId }

    func poll(now: Date, processes: [ProcessEntry], loop: LoopState?) -> [AgentSession] {
        let loopLog = loop?.log
        if reader.path != loopLog { reader.reset(path: loopLog) }
        _ = reader.poll()

        var runs: [ProcessEntry] = []
        var hubs: [ProcessEntry] = []
        var workspaces = Set<String>()
        let agy = processes.filter { $0.path.hasSuffix("/agy") }
        argumentsByPid = argumentsByPid.filter { pid, _ in agy.contains { $0.pid == pid } }
        projectByPid = projectByPid.filter { pid, _ in agy.contains { $0.pid == pid } }
        for process in agy {
            let args = argumentsByPid[process.pid] ?? ProcessSnapshot.arguments(of: process.pid)
            argumentsByPid[process.pid] = args
            if args.contains("--hub") {
                hubs.append(process)
                workspaces.formUnion(Self.addedDirectories(in: args))
            } else if args.contains(" -p ") || args.contains(" --print") || args.contains(" --prompt ") {
                runs.append(process)
            }
        }

        loopOutcome = runs.isEmpty ? reader.outcome : nil
        var sessions: [AgentSession] = []
        let loopActive = loop?.status == "gemini"
        for (index, process) in runs.enumerated() {
            // The loop starts one run at a time, so the first run is the one writing the loop log.
            if index == 0 && loopActive, let loop {
                sessions.append(loopSession(loop, state: .working, process: process))
            } else {
                let args = argumentsByPid[process.pid] ?? ""
                let project = projectDirectory(of: process.pid, arguments: args)
                var detail = "Berjalan \(process.elapsed)"
                if let model = Self.flag("--model", in: args) { detail += " · \(model)" }
                sessions.append(AgentSession(
                    id: "gemini-cli:\(process.pid)", kind: .geminiCLI,
                    title: Format.folderName(project) ?? "Gemini CLI", project: project, state: .working,
                    detail: detail, cpu: process.cpu, memoryMB: process.memoryMB, model: Self.flag("--model", in: args)))
            }
        }

        // Keep showing how the last loop run ended, for as long as other sessions stay visible.
        if !(loopActive && !runs.isEmpty), let loop, let log = loop.log, let outcome = reader.outcome,
           let finished = FileScan.modificationDate(log), now.timeIntervalSince(finished) < ClaudeCodeProvider.window {
            let success = outcome.status == "SUCCESS"
            var session = loopSession(loop, state: success ? .finished : .failed, process: nil)
            session.detail = success ? "Putaran selesai" : "Berhenti: \(outcome.error ?? outcome.status)"
            session.lastActivity = finished
            sessions.append(session)
        }

        let app = processes.filter { $0.path.contains("/Gemini.app/") }
        if !app.isEmpty {
            let all = app + hubs
            var detail = hubs.isEmpty ? "Aplikasi terbuka" : "\(hubs.count) hub agen"
            if !workspaces.isEmpty {
                detail += " · " + workspaces.compactMap(Format.folderName).sorted().joined(separator: ", ")
            }
            sessions.append(AgentSession(
                id: "gemini:app", kind: .geminiApp, title: "Aplikasi Gemini", state: .running, detail: detail,
                cpu: all.reduce(0) { $0 + $1.cpu }, memoryMB: all.reduce(0) { $0 + $1.memoryMB }))
        }
        return sessions
    }

    /// The loop run keeps one id from start to finish, so its working → finished change can be noticed.
    private func loopSession(_ loop: LoopState, state: AgentState, process: ProcessEntry?) -> AgentSession {
        let label = [loop.phase, loop.round.map { "putaran \($0)" }].compactMap { $0 }.joined(separator: " · ")
        let latest = reader.visibleActivities(limit: 1).first
        let detail = latest.map { "\($0.title) \($0.detail)" } ?? "Berjalan \(process?.elapsed ?? "")"
        return AgentSession(
            id: "gemini-cli:loop", kind: .geminiCLI,
            title: label.isEmpty ? "Loop" : "Loop · \(label)",
            project: loop.project, state: state, detail: detail, lastActivity: reader.lastEventAt,
            tokens: reader.totalTokens > 0 ? reader.totalTokens : nil,
            cpu: process?.cpu, memoryMB: process?.memoryMB, model: reader.model,
            activities: reader.visibleActivities(limit: 30), logPath: loop.log)
    }

    /// The run's working directory, or its first `--add-dir` when it was started from home or `/`.
    private func projectDirectory(of pid: Int, arguments: String) -> String? {
        if let known = projectByPid[pid] { return known }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var project = ProcessSnapshot.workingDirectory(of: pid)
        if project == nil || project == home || project == "/" {
            project = Self.addedDirectories(in: arguments).first ?? project
        }
        projectByPid[pid] = project
        return project
    }

    private static func addedDirectories(in args: String) -> [String] {
        args.components(separatedBy: "--add-dir").dropFirst().compactMap { part -> String? in
            // `--add-dir=PATH` or `--add-dir PATH`. Paths may contain spaces; the next flag starts with " --".
            let value = part.drop { $0 == "=" || $0 == " " }
            return value.components(separatedBy: " --").first?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
    }

    /// Value of a `--name value` or `--name=value` flag.
    private static func flag(_ name: String, in args: String) -> String? {
        guard let range = args.range(of: name + " ") ?? args.range(of: name + "=") else { return nil }
        return args[range.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)
    }
}
