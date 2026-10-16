import Foundation

package enum AgentKind: String, Sendable {
    case claudeCode, codex, geminiCLI, geminiApp, copilot, claudeDesktop, chatGPT, ollama

    package var name: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .geminiCLI: return "Gemini CLI"
        case .geminiApp: return "Gemini"
        case .copilot: return "GitHub Copilot"
        case .claudeDesktop: return "Claude"
        case .chatGPT: return "ChatGPT"
        case .ollama: return "Ollama"
        }
    }

    package var symbol: String {
        switch self {
        case .claudeCode: return "chevron.left.forwardslash.chevron.right"
        case .codex: return "curlybraces"
        case .geminiCLI, .geminiApp: return "sparkles"
        case .copilot: return "airplane"
        case .claudeDesktop: return "bubble.left.and.bubble.right"
        case .chatGPT: return "bubble.left"
        case .ollama: return "cpu"
        }
    }
}

/// Raw values give the display order: what needs the user comes first.
package enum AgentState: Int, Comparable, Sendable {
    case needsPermission, waiting, working, failed, finished, idle, running

    package static func < (lhs: AgentState, rhs: AgentState) -> Bool { lhs.rawValue < rhs.rawValue }

    package var label: String {
        switch self {
        case .needsPermission: return "Butuh izin"
        case .waiting: return "Menunggu Anda"
        case .working: return "Bekerja"
        case .failed: return "Error"
        case .finished: return "Selesai"
        case .idle: return "Diam"
        case .running: return "Terbuka"
        }
    }
}

/// One agent session (or one running AI app) as shown in the panel.
package struct AgentSession: Identifiable, Sendable {
    package let id: String
    package let kind: AgentKind
    package var title: String
    package var project: String? = nil
    package var state: AgentState
    package var detail = ""
    package var lastActivity: Date? = nil
    package var tokens: Int? = nil
    package var costUSD: Double? = nil
    package var cpu: Double? = nil
    package var memoryMB: Int? = nil
    /// The model id the session last used.
    package var model: String? = nil
    package var activities: [Activity] = []
    package var logPath: String? = nil

    package init(
        id: String,
        kind: AgentKind,
        title: String,
        project: String? = nil,
        state: AgentState,
        detail: String = "",
        lastActivity: Date? = nil,
        tokens: Int? = nil,
        costUSD: Double? = nil,
        cpu: Double? = nil,
        memoryMB: Int? = nil,
        model: String? = nil,
        activities: [Activity] = [],
        logPath: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.project = project
        self.state = state
        self.detail = detail
        self.lastActivity = lastActivity
        self.tokens = tokens
        self.costUSD = costUSD
        self.cpu = cpu
        self.memoryMB = memoryMB
        self.model = model
        self.activities = activities
        self.logPath = logPath
    }

    /// Agents that are done or quiet can be closed from the panel; a working one stays in view.
    package var canDismiss: Bool { state != .working && state != .needsPermission }

    /// Claude Code and Codex CLI sessions can be jumped to in their host terminal/editor.
    package var canJump: Bool {
        (kind == .claudeCode || kind == .codex) && project != nil
    }
}

package struct Activity: Identifiable, Sendable {
    package enum Kind: Sendable {
        case prompt, read, search, edit, command, browse, response, thinking, other

        package var symbol: String {
            switch self {
            case .prompt: return "person.fill"
            case .read: return "doc.text"
            case .search: return "magnifyingglass"
            case .edit: return "pencil"
            case .command: return "terminal"
            case .browse: return "globe"
            case .response: return "text.bubble"
            case .thinking: return "brain"
            case .other: return "wrench.and.screwdriver"
            }
        }
    }

    package let id: Int
    package var kind: Kind = .other
    package var title = ""
    package var detail = ""
    package var active = true
    package var duration: Double?
    package var startedAt = Date()

    /// Maps an agy (Gemini) tool name to an activity kind and an Indonesian label.
    static func describe(geminiTool tool: String) -> (Kind, String) {
        switch tool {
        case "view_file", "read_resource": return (.read, "Membaca")
        case "list_dir": return (.read, "Melihat folder")
        case "grep_search", "find_by_name": return (.search, "Mencari")
        case "write_to_file": return (.edit, "Membuat file")
        case "replace_file_content", "multi_replace_file_content", "sed_file", "notebook_edit":
            return (.edit, "Mengedit")
        case "run_command", "send_command_input": return (.command, "Menjalankan")
        case "command_status", "wait", "wait_5_seconds": return (.command, "Menunggu perintah")
        case "read_url_content", "search_web": return (.browse, "Membuka web")
        case "finish": return (.other, "Menyelesaikan")
        default:
            if tool.contains("browser") { return (.browse, "Browser") }
            return (.other, tool)
        }
    }

    /// Maps a Claude Code tool name to an activity kind and an Indonesian label.
    static func describe(claudeTool tool: String) -> (Kind, String) {
        switch tool {
        case "Read": return (.read, "Membaca")
        case "Write": return (.edit, "Menulis file")
        case "Edit", "MultiEdit", "NotebookEdit": return (.edit, "Mengedit")
        case "Bash", "BashOutput", "KillShell": return (.command, "Menjalankan")
        case "Grep", "Glob": return (.search, "Mencari")
        case "WebFetch", "WebSearch": return (.browse, "Membuka web")
        case "Agent", "Task": return (.other, "Subagen")
        default: return (.other, shortToolName(tool))
        }
    }

    /// `mcp__server__tool` → `tool`.
    static func shortToolName(_ name: String) -> String {
        name.components(separatedBy: "__").last ?? name
    }

    /// Picks the most telling parameter of a tool call (command line, file path, query).
    package static func summary(of parameters: [String: Any]) -> String {
        let preferred = ["CommandLine", "command", "AbsolutePath", "TargetFile", "file_path", "notebook_path",
                         "DirectoryPath", "SearchPath", "SearchDirectory", "path", "Query", "query",
                         "Pattern", "pattern", "Url", "URL", "url", "description", "skill", "prompt"]
        for key in preferred {
            if let value = parameters[key] as? String, !value.isEmpty { return value }
        }
        return parameters.values.compactMap { $0 as? String }.first ?? ""
    }
}

/// One Claude plan limit; `used` is the percentage of its allowance already spent.
struct UsageLimit: Identifiable, Equatable {
    let id: String
    let kind: String
    let title: String
    let used: Double
    let resetsAt: Date?

    var remaining: Double { max(0, 100 - used) }
}

/// The plan limits of one agent's account.
struct PlanUsage: Equatable {
    let kind: AgentKind
    var plan: String?
    var limits: [UsageLimit] = []
    /// Something the user should know beyond the numbers, such as a limit already reached.
    var note: String?
    var fetchedAt: Date?
    /// Why the latest refresh failed; the limits from the last good one stay.
    var error: String?
}

/// What one agent is set to use, what its sessions use, and what it offers.
struct AgentModels: Identifiable, Equatable {
    struct InUse: Identifiable, Equatable {
        var id: String { model }
        let model: String
        let sessions: [String]
    }

    var id: AgentKind { kind }
    let kind: AgentKind
    var title: String
    var configured: String?
    var inUse: [InUse] = []
    var available: [String] = []
}

/// Loop state that Claude and the panel write to ~/.aegis-loop/state.json at every hand-off.
package struct LoopState: Codable, Equatable, Sendable {
    package var project: String?
    package var phase: String?
    package var round: Int?
    package var status: String?
    package var note: String?
    package var log: String?
    package var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case project, phase, round, status, note, log
        case updatedAt = "updated_at"
    }
}

package enum LoopStatus: Equatable, Sendable {
    case gemini, claude, idle, done, blocked, none

    package init(_ raw: String?) {
        switch raw {
        case "gemini": self = .gemini
        case "claude": self = .claude
        case "idle": self = .idle
        case "done": self = .done
        case "blocked": self = .blocked
        default: self = .none
        }
    }

    /// The statuses the user can set from the panel.
    static let settable: [LoopStatus] = [.gemini, .claude, .blocked, .idle, .done]

    package var raw: String? {
        switch self {
        case .gemini: return "gemini"
        case .claude: return "claude"
        case .idle: return "idle"
        case .done: return "done"
        case .blocked: return "blocked"
        case .none: return nil
        }
    }

    package var title: String {
        switch self {
        case .gemini: return "Gemini sedang bekerja"
        case .claude: return "Claude sedang me-review"
        case .idle: return "Dijeda"
        case .done: return "Selesai"
        case .blocked: return "Butuh keputusan Anda"
        case .none: return "Belum ada putaran"
        }
    }

    package var symbol: String {
        switch self {
        case .gemini: return "sparkles"
        case .claude: return "eye"
        case .idle: return "pause.circle"
        case .done: return "checkmark.seal"
        case .blocked: return "exclamationmark.triangle"
        case .none: return "moon.zzz"
        }
    }
}

package struct ChangedFile: Identifiable, Equatable, Sendable {
    package var id: String { path }
    package let status: String
    package let path: String
}

package struct ReviewCounts: Equatable, Sendable {
    package var open = 0
    package var fixed = 0
    package var rejected = 0

    package init(open: Int = 0, fixed: Int = 0, rejected: Int = 0) {
        self.open = open
        self.fixed = fixed
        self.rejected = rejected
    }
}

package struct LoopSnapshot: Equatable, Sendable {
    package var state: LoopState
    package var review = ReviewCounts()
    package var changes: [ChangedFile] = []
    package var diffSummary = ""

    package var status: LoopStatus { LoopStatus(state.status) }

    package var subtitle: String {
        var parts: [String] = []
        if let phase = state.phase, !phase.isEmpty { parts.append("Tahap \(phase)") }
        if let round = state.round { parts.append("Putaran \(round)") }
        var text = parts.joined(separator: " · ")
        if let note = state.note, !note.isEmpty { text += text.isEmpty ? note : " — \(note)" }
        return text
    }

    package init(state: LoopState, review: ReviewCounts = ReviewCounts(), changes: [ChangedFile] = [], diffSummary: String = "") {
        self.state = state
        self.review = review
        self.changes = changes
        self.diffSummary = diffSummary
    }
}
