import AppKit
import Foundation
import ServiceManagement

@MainActor
package final class MonitorModel: ObservableObject {
    /// The agents on show; the ones the user closed are in `dismissedAgents`.
    @Published private(set) var agents: [AgentSession] = []
    @Published private(set) var dismissedAgents: [AgentSession] = []
    @Published private(set) var loop: LoopSnapshot?
    /// Plan limits per agent, for the agents whose limits can be read.
    @Published private(set) var usage: [AgentKind: PlanUsage] = [:]
    @Published private(set) var usageLoading = false
    @Published private(set) var usageCheckedAt: Date?
    @Published private(set) var modelsLoading = false
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// nil when agy's settings.json exists but cannot be parsed.
    @Published private(set) var agyPermissions: AgyPermissions?
    @Published private(set) var loopRunning = false
    /// Why the last loop action failed, shown in the loop tab.
    @Published private(set) var loopError: String?
    @Published var notificationsOn: Bool {
        didSet { UserDefaults.standard.set(notificationsOn, forKey: "notificationsOn") }
    }

    private let claude = ClaudeCodeProvider()
    private let codex = CodexProvider()
    private let gemini = GeminiProvider()
    private let aegis = AegisLoop()
    private let catalog = ModelCatalog()
    private let runner = LoopRunner()
    private let live: Bool
    private var timer: Timer?
    private var usageAttemptAt = Date.distantPast
    private var previous: [String: AgentSession] = [:]
    private var previousLoopStatus: String?
    private var primed = false
    private var all: [AgentSession] = []
    /// Closed agents, keyed by id, with the last activity they had when closed.
    private var dismissed: [String: Date] {
        didSet {
            UserDefaults.standard.set(dismissed.mapValues(\.timeIntervalSince1970), forKey: "dismissedAgents")
        }
    }

    /// Agents whose limits are read, in the order the usage tab shows them.
    static let usageKinds: [AgentKind] = [.claudeCode, .codex]

    /// Models per agent; read from files that are cached until they change, so it is cheap to ask often.
    var models: [AgentModels] { catalog.snapshot(sessions: all) }

    var waitingCount: Int { agents.filter { $0.state == .waiting }.count }
    var workingCount: Int { agents.filter { $0.state == .working }.count }
    var dismissableCount: Int { agents.filter(\.canDismiss).count }

    /// The loop shows while it runs or needs the user, was handed off recently, or an agent is open in its project.
    /// A loop paused or finished long ago stays out of sight.
    var visibleLoop: LoopSnapshot? {
        guard let loop else { return nil }
        if [.gemini, .claude, .blocked].contains(loop.status) { return loop }
        if let updated = ISODate.parse(loop.state.updatedAt),
           Date().timeIntervalSince(updated) < ClaudeCodeProvider.window { return loop }
        if let project = loop.state.project,
           agents.contains(where: { $0.project == project || $0.project?.hasPrefix(project + "/") == true }) {
            return loop
        }
        return nil
    }

    /// `live: false` polls once without timer or notifications, for `--dump`.
    package init(live: Bool = true) {
        self.live = live
        notificationsOn = UserDefaults.standard.object(forKey: "notificationsOn") as? Bool ?? true
        let stored = UserDefaults.standard.dictionary(forKey: "dismissedAgents") as? [String: Double] ?? [:]
        dismissed = stored.mapValues(Date.init(timeIntervalSince1970:))
        guard live else { return }
        Notifier.requestPermission()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    /// Prints what the panel would show, so detection can be checked from a terminal.
    package static func dump() {
        let model = MonitorModel(live: false)
        model.refresh()
        let relative = RelativeDateTimeFormatter()
        for agent in model.agents + model.dismissedAgents {
            let when = agent.lastActivity.map { relative.localizedString(for: $0, relativeTo: Date()) } ?? "-"
            let closed = model.dismissed[agent.id] != nil ? " (ditutup)" : ""
            print("[\(agent.state.label)] \(agent.kind.name) · \(agent.title) · \(Format.folderName(agent.project) ?? "-") · \(when)\(closed)")
            if !agent.detail.isEmpty { print("    \(Format.snippet(agent.detail, limit: 110))") }
            for activity in agent.activities.prefix(3) {
                print("      - \(activity.title): \(Format.snippet(activity.detail, limit: 80))\(activity.active ? " (aktif)" : "")")
            }
        }
        if let loop = model.loop {
            let hidden = model.visibleLoop == nil ? " (disembunyikan)" : ""
            print("Loop \(Format.folderName(loop.state.project) ?? "-"): \(loop.status.title) · \(loop.subtitle) · \(loop.changes.count) file berubah\(hidden)")
        }

        for agent in model.models {
            print("Model \(agent.title): bawaan \(agent.configured ?? "-")")
            for use in agent.inUse { print("    dipakai \(use.model) · \(use.sessions.joined(separator: ", "))") }
            if !agent.available.isEmpty { print("    tersedia \(agent.available.joined(separator: ", "))") }
        }

        // The fetches do not need the main actor, so waiting for them here cannot deadlock.
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for (kind, result) in await fetchUsage() {
                switch result {
                case .success(nil):
                    print("Usage \(kind.name): tidak terpasang")
                case .success(let usage?):
                    print("Usage \(kind.name)\(usage.plan.map { " (\($0))" } ?? ""):")
                    for limit in usage.limits {
                        let reset = limit.resetsAt.map { " · reset \(Format.moment($0))" } ?? ""
                        print("    \(limit.title): \(Format.percent(limit.used)) terpakai, \(Format.percent(limit.remaining)) tersisa\(reset)")
                    }
                    if let note = usage.note { print("    \(note)") }
                case .failure(let error):
                    print("Usage \(kind.name): \(error.localizedDescription)")
                }
            }
            done.signal()
        }
        done.wait()
    }

    func refresh() {
        let now = Date()
        let processes = ProcessSnapshot.capture()
        let snapshot = aegis.refresh()

        var sessions = claude.poll(now: now, processes: processes)
        sessions += codex.poll(now: now, processes: processes)
        sessions += gemini.poll(now: now, processes: processes, loop: snapshot?.state)
        sessions += PresenceProvider.poll(processes: processes)
        // What needs the user first, then the most recently active.
        sessions.sort {
            ($0.state, $1.lastActivity ?? .distantPast) < ($1.state, $0.lastActivity ?? .distantPast)
        }

        notifyChanges(sessions, loop: snapshot)
        all = sessions
        applyDismissals()
        if let state = snapshot?.state {
            if state != loop?.state { LoopStore.remember(state) }
            if let project = state.project, let id = gemini.loopConversationId {
                LoopStore.setConversation(id, for: project)
            }
        }
        if snapshot != loop { loop = snapshot }
        if live {
            refreshUsage()
            // A run the panel did not start (Claude's, or one left from before a relaunch) hands off here once it ends.
            if let state = snapshot?.state, state.status == "gemini", !runner.isRunning, let outcome = gemini.loopOutcome {
                finishRound(state, status: outcome.status, error: outcome.error)
            }
        }
    }

    // MARK: - Plan usage and models

    /// The limits move slowly and the endpoints throttle, so they are fetched every 5 minutes by default,
    /// and within a minute once a window has reset.
    func refreshUsage(ifOlderThan maxAge: TimeInterval = 300) {
        let now = Date()
        let windowReset = usage.values.contains { $0.limits.contains { ($0.resetsAt ?? .distantFuture) <= now } }
        guard !usageLoading, now.timeIntervalSince(usageAttemptAt) >= (windowReset ? min(maxAge, 60) : maxAge) else { return }
        usageAttemptAt = now
        usageLoading = true
        Task {
            for (kind, result) in await Self.fetchUsage() {
                switch result {
                case .success(let fresh):
                    usage[kind] = fresh
                case .failure(let error):
                    // Keep the last good numbers next to the reason they could not be refreshed.
                    var stale = usage[kind] ?? PlanUsage(kind: kind)
                    stale.error = error.localizedDescription
                    usage[kind] = stale
                }
            }
            usageCheckedAt = Date()
            usageLoading = false
        }
    }

    /// Asks every agent's endpoint at once; nil means the agent is not set up on this Mac.
    private nonisolated static func fetchUsage() async -> [(AgentKind, Result<PlanUsage?, Error>)] {
        async let claude = attempt { try await ClaudeUsageProvider.fetch() }
        async let codex = attempt { try await CodexUsageProvider.fetch() }
        return await [(.claudeCode, claude), (.codex, codex)]
    }

    private nonisolated static func attempt(_ fetch: () async throws -> PlanUsage?) async -> Result<PlanUsage?, Error> {
        do {
            return .success(try await fetch())
        } catch {
            return .failure(error)
        }
    }

    /// Refreshes the Gemini model list, which comes from `agy models` over the network.
    func refreshModels(force: Bool = false) {
        guard AgentKind.geminiCLI.isInstalled, !modelsLoading, force || catalog.agyStale else { return }
        modelsLoading = true
        Task {
            let lines = await Task.detached { ModelCatalog.fetchAgyModels() }.value
            if let lines { catalog.storeAgyModels(lines, at: Date()) }
            modelsLoading = false
        }
    }

    // MARK: - Loop control

    /// Projects the loop has run in, the active one first.
    var loopProjects: [String] {
        var projects = loop?.state.project.map { [$0] } ?? []
        for project in LoopStore.knownProjects where !projects.contains(project) { projects.append(project) }
        return projects
    }

    /// Gemini models from `agy models`, as (id, name).
    var agyModelChoices: [(id: String, name: String)] {
        catalog.agyModels.compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    /// The conversation of the active project's last Gemini run, which the next task can continue.
    var loopConversation: String? { loop?.state.project.flatMap(LoopStore.conversation(for:)) }

    /// The loop's Gemini run as the monitor tab shows it, with its live activity.
    var loopSession: AgentSession? { all.first { $0.id == "gemini-cli:loop" } }

    func refreshLoopControl() {
        agyPermissions = AgyPermissions.load()
    }

    /// Makes another project the active loop, picking up where that project's loop was left.
    func selectLoopProject(_ project: String) {
        guard !runner.isRunning, project != loop?.state.project else { return }
        var next = LoopStore.saved(for: project)
            ?? LoopState(project: project, round: 0, status: LoopStatus.idle.raw, note: "Belum ada putaran")
        // A run recorded as working there is not running now.
        if next.status == LoopStatus.gemini.raw { next.status = LoopStatus.idle.raw }
        writeLoopState(next)
    }

    func setLoopStatus(_ status: LoopStatus) {
        guard var state = loop?.state, state.status != status.raw else { return }
        state.status = status.raw
        state.note = nil
        writeLoopState(state)
    }

    func setAgyFolder(_ folder: String, allowed: Bool) {
        changePermissions { $0.setFolder(folder, allowed: allowed) }
    }

    func setAgyCommand(_ command: String, allowed: Bool) {
        let command = command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return }
        changePermissions { $0.setCommand(command, allowed: allowed) }
    }

    private func changePermissions(_ change: (inout AgyPermissions) -> Void) {
        guard var permissions = AgyPermissions.load() else {
            loopError = "settings.json agy tidak bisa dibaca, jadi tidak diubah."
            return
        }
        change(&permissions)
        do {
            try permissions.save()
            loopError = nil
        } catch {
            loopError = "Izin agy tidak bisa disimpan: \(error.localizedDescription)"
        }
        refreshLoopControl()
    }

    /// Sends a task to Gemini as a headless `agy -p` run in the active project.
    func startRound(prompt: String, model agyModel: String, phase: String, round: Int, continueConversation: Bool) {
        guard let project = loop?.state.project, !runner.isRunning else { return }
        let request = LoopRunner.Request(
            project: project, prompt: prompt, model: agyModel,
            conversation: continueConversation ? loopConversation : nil, round: round)
        do {
            let log = try runner.start(request) { [weak self] log in
                Task { @MainActor in self?.roundEnded(log: log) }
            }
            loopRunning = true
            writeLoopState(LoopState(
                project: project, phase: phase.isEmpty ? nil : phase, round: round,
                status: LoopStatus.gemini.raw, note: "Model \(agyModel)", log: log))
        } catch {
            loopError = "Gemini tidak bisa dijalankan: \(error.localizedDescription)"
        }
    }

    func stopRound() {
        runner.stop()
    }

    private func roundEnded(log: String) {
        loopRunning = runner.isRunning
        guard let state = LoopStore.read(), state.log == log, state.status == LoopStatus.gemini.raw else {
            refresh()
            return
        }
        let reader = StreamReader()
        reader.reset(path: log)
        _ = reader.poll()
        if let project = state.project, let id = reader.conversationId { LoopStore.setConversation(id, for: project) }
        finishRound(state, status: reader.outcome?.status, error: reader.outcome?.error, stopped: runner.stopped)
    }

    /// Hands the loop to Claude after a good run, or to the user when the run failed or was stopped.
    private func finishRound(_ state: LoopState, status: String?, error: String?, stopped: Bool = false) {
        var state = state
        if status == "SUCCESS" {
            state.status = LoopStatus.claude.raw
            state.note = "Gemini selesai. Minta Claude me-review."
        } else if stopped {
            state.status = LoopStatus.idle.raw
            state.note = "Dihentikan dari panel"
        } else {
            state.status = LoopStatus.blocked.raw
            state.note = "Gemini berhenti: \(error ?? status ?? "tanpa hasil")"
        }
        writeLoopState(state)
    }

    private func writeLoopState(_ state: LoopState) {
        do {
            try LoopStore.write(state)
            loopError = nil
        } catch {
            loopError = "state.json tidak bisa ditulis: \(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: - Closing agents

    /// Stops showing an agent until it works again or shows newer activity.
    func dismiss(_ id: String) {
        guard let agent = all.first(where: { $0.id == id }), agent.canDismiss else { return }
        dismissed[id] = agent.lastActivity ?? .distantPast
        applyDismissals()
    }

    /// Closes every agent that has finished or has nothing going on.
    func dismissInactive() {
        for agent in agents where agent.canDismiss {
            dismissed[agent.id] = agent.lastActivity ?? .distantPast
        }
        applyDismissals()
    }

    func undismiss(_ id: String) {
        dismissed[id] = nil
        applyDismissals()
    }

    func undismissAll() {
        dismissed = [:]
        applyDismissals()
    }

    /// A closed agent comes back once it works or has activity newer than when it was closed.
    /// One that is no longer detected at all (session expired, app quit) is forgotten.
    private func applyDismissals() {
        var kept: [String: Date] = [:]
        var shown: [AgentSession] = []
        var hidden: [AgentSession] = []
        for agent in all {
            if let closedAt = dismissed[agent.id], agent.canDismiss, (agent.lastActivity ?? .distantPast) <= closedAt {
                kept[agent.id] = closedAt
                hidden.append(agent)
            } else {
                shown.append(agent)
            }
        }
        if kept != dismissed { dismissed = kept }
        agents = shown
        dismissedAgents = hidden
    }

    // MARK: - Actions

    nonisolated func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Logs open in Console, which follows the file live.
    nonisolated func openLog(_ path: String) {
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: console,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("AgentMonitor: launch at login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Notifications

    private func notifyChanges(_ sessions: [AgentSession], loop snapshot: LoopSnapshot?) {
        defer {
            previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            previousLoopStatus = snapshot?.state.status
            primed = true
        }
        // The first pass only records what is already going on.
        guard primed, notificationsOn else { return }

        for session in sessions {
            guard let before = previous[session.id], before.state != session.state else { continue }
            switch session.state {
            case .waiting where before.state == .working:
                Notifier.post("\(session.kind.name) menunggu Anda", "\(session.title): \(session.detail)")
            case .failed:
                Notifier.post("\(session.kind.name) error", "\(session.title): \(session.detail)")
            case .finished where before.state == .working:
                Notifier.post("\(session.kind.name) selesai", session.title)
            default:
                break
            }
        }

        let current = Set(sessions.map(\.id))
        for (id, before) in previous where !current.contains(id) && before.kind == .geminiCLI && before.state == .working {
            Notifier.post("Gemini CLI berhenti", before.title)
        }

        if let status = snapshot?.state.status, status != previousLoopStatus, let snapshot {
            Notifier.post("Loop \(Format.folderName(snapshot.state.project) ?? ""): \(snapshot.status.title)", snapshot.subtitle)
        }
    }
}
