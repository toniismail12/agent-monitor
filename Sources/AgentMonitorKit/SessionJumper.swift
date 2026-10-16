import AppKit
import Foundation

/// Entry parsed from `ps -o pid=,ppid=,tty=,comm=`.
package struct ProcessTreeEntry: Equatable, Sendable {
    package let pid: Int
    package let ppid: Int
    package let tty: String?
    package let comm: String

    package init(pid: Int, ppid: Int, tty: String?, comm: String) {
        self.pid = pid
        self.ppid = ppid
        self.tty = (tty != nil && tty != "??" && !tty!.isEmpty) ? tty : nil
        self.comm = comm
    }
}

/// Information about the host application hosting the agent process.
package struct HostAppInfo: Equatable, Sendable {
    package let pid: Int
    package let bundleId: String?
    package let appPath: String

    package init(pid: Int, bundleId: String?, appPath: String) {
        self.pid = pid
        self.bundleId = bundleId
        self.appPath = appPath
    }
}

/// Action to jump to an agent session.
package enum JumpAction: Equatable, Sendable {
    case terminal(script: String)
    case iterm(script: String)
    case openProject(bundleId: String, path: String)
    case activateApp(pid: Int)
    case notFound
}

/// Locates the running process for an agent session and determines the jump action.
package enum SessionJumper {

    /// Parses the output of `ps -o pid=,ppid=,tty=,comm=` into a dictionary of entries keyed by PID.
    package static func parseProcessTree(_ output: String) -> [Int: ProcessTreeEntry] {
        var tree: [Int: ProcessTreeEntry] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let fields = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4,
                  let pid = Int(fields[0]),
                  let ppid = Int(fields[1]) else { continue }
            let tty = String(fields[2])
            let comm = fields[3].trimmingCharacters(in: .whitespaces)
            tree[pid] = ProcessTreeEntry(pid: pid, ppid: ppid, tty: tty, comm: comm)
        }
        return tree
    }

    /// Extracts the outermost `.app` bundle path from a process executable path.
    package static func outermostAppPath(from path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        var accum: [Substring] = []
        for comp in components {
            accum.append(comp)
            if comp.hasSuffix(".app") {
                return accum.joined(separator: "/")
            }
        }
        return nil
    }

    /// Resolves the bundle identifier for an application path, reading its bundle or falling back to known identifiers.
    package static func bundleIdentifier(for appPath: String) -> String? {
        if let bundle = Bundle(path: appPath), let id = bundle.bundleIdentifier {
            return id
        }
        let name = (appPath as NSString).lastPathComponent.lowercased()
        if name.contains("terminal") {
            return "com.apple.Terminal"
        }
        if name.contains("iterm") {
            return "com.googlecode.iterm2"
        }
        if name.contains("cursor") {
            return "com.todesktop.230313mzl4w4u92"
        }
        if name.contains("code") {
            return "com.microsoft.VSCode"
        }
        return nil
    }

    /// Checks if a process is a candidate for a given agent kind based on its path.
    package static func isCandidateProcess(comm: String, kind: AgentKind) -> Bool {
        switch kind {
        case .claudeCode:
            return comm.contains("anthropic.claude-code") || comm.hasSuffix("/claude") || comm == "claude"
        case .codex:
            return comm.hasSuffix("/codex") || comm == "codex"
        default:
            return false
        }
    }

    /// Finds candidate processes for a given agent kind from the process tree.
    package static func findCandidateProcesses(for kind: AgentKind, in tree: [Int: ProcessTreeEntry]) -> [ProcessTreeEntry] {
        tree.values.filter { isCandidateProcess(comm: $0.comm, kind: kind) }
    }

    /// Checks if the process working directory matches or is inside the agent's project directory.
    package static func matchesProject(processCwd: String, projectPath: String) -> Bool {
        let normProj = normalizePath(projectPath)
        let normCwd = normalizePath(processCwd)
        guard !normProj.isEmpty && !normCwd.isEmpty else { return false }
        if normCwd == normProj { return true }
        if normCwd.hasPrefix(normProj + "/") { return true }
        return false
    }

    private static func normalizePath(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.hasSuffix("/") && p.count > 1 {
            p.removeLast()
        }
        return p
    }

    /// Selects the best candidate process matching the project path, preferring ones with a TTY.
    package static func pickBestProcess(
        candidates: [ProcessTreeEntry],
        projectPath: String,
        cwdSupplier: (Int) -> String?
    ) -> ProcessTreeEntry? {
        var matchingCandidates: [ProcessTreeEntry] = []
        for candidate in candidates {
            if let cwd = cwdSupplier(candidate.pid), matchesProject(processCwd: cwd, projectPath: projectPath) {
                matchingCandidates.append(candidate)
            }
        }
        guard !matchingCandidates.isEmpty else { return nil }

        let withTTY = matchingCandidates.filter { $0.tty != nil && $0.tty != "??" && !$0.tty!.isEmpty }
        if let best = withTTY.first {
            return best
        }
        return matchingCandidates.first
    }

    /// Traces the parent process chain to find the host application bundle.
    package static func findHostApp(
        for pid: Int,
        in tree: [Int: ProcessTreeEntry],
        bundleIdResolver: (String) -> String? = bundleIdentifier
    ) -> HostAppInfo? {
        var visited = Set<Int>()
        var currentPid = pid

        while currentPid > 1, !visited.contains(currentPid), let current = tree[currentPid] {
            visited.insert(currentPid)
            let parentPid = current.ppid
            guard parentPid > 0, let parent = tree[parentPid] else { break }

            if let appPath = outermostAppPath(from: parent.comm) {
                var topPid = parent.pid
                var walkerPid = parent.ppid
                while walkerPid > 1, !visited.contains(walkerPid), let higher = tree[walkerPid] {
                    visited.insert(walkerPid)
                    if let higherApp = outermostAppPath(from: higher.comm), higherApp == appPath {
                        topPid = higher.pid
                        walkerPid = higher.ppid
                    } else {
                        break
                    }
                }
                let bundleId = bundleIdResolver(appPath)
                return HostAppInfo(pid: topPid, bundleId: bundleId, appPath: appPath)
            }
            currentPid = parentPid
        }
        return nil
    }

    /// Escapes double quotes and backslashes for safe inclusion in AppleScript string literals.
    package static func escapeForAppleScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Generates AppleScript to select the Terminal.app tab matching the target TTY.
    package static func terminalAppleScript(for tty: String) -> String {
        let devTTY = tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
        let escaped = escapeForAppleScript(devTTY)
        return """
        tell application id "com.apple.Terminal"
            activate
            set targetTTY to "\(escaped)"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is targetTTY then
                        set selected of t to true
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    }

    /// Generates AppleScript to select the iTerm2 session matching the target TTY.
    package static func itermAppleScript(for tty: String) -> String {
        let devTTY = tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
        let escaped = escapeForAppleScript(devTTY)
        return """
        tell application id "com.googlecode.iterm2"
            activate
            set targetTTY to "\(escaped)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is targetTTY then
                            select t
                            select s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    /// Determines the jump action based on the host application, TTY, and project path.
    package static func determineAction(host: HostAppInfo?, tty: String?, projectPath: String?) -> JumpAction {
        guard let host else {
            return .notFound
        }

        let cleanTTY = (tty != nil && tty != "??" && !tty!.isEmpty) ? tty : nil
        let bundleId = host.bundleId ?? ""

        if bundleId == "com.apple.Terminal" || host.appPath.hasSuffix("/Terminal.app") {
            if let cleanTTY {
                let script = terminalAppleScript(for: cleanTTY)
                return .terminal(script: script)
            } else {
                return .activateApp(pid: host.pid)
            }
        }

        if bundleId == "com.googlecode.iterm2" || host.appPath.hasSuffix("/iTerm.app") || host.appPath.hasSuffix("/iTerm2.app") {
            if let cleanTTY {
                let script = itermAppleScript(for: cleanTTY)
                return .iterm(script: script)
            } else {
                return .activateApp(pid: host.pid)
            }
        }

        if bundleId == "com.microsoft.VSCode" || bundleId == "com.todesktop.230313mzl4w4u92"
            || host.appPath.contains("Visual Studio Code.app") || host.appPath.contains("Cursor.app") {
            if let projectPath, !projectPath.isEmpty {
                let resolvedId: String
                if !bundleId.isEmpty {
                    resolvedId = bundleId
                } else if host.appPath.contains("Cursor.app") {
                    resolvedId = "com.todesktop.230313mzl4w4u92"
                } else {
                    resolvedId = "com.microsoft.VSCode"
                }
                return .openProject(bundleId: resolvedId, path: projectPath)
            } else {
                return .activateApp(pid: host.pid)
            }
        }

        return .activateApp(pid: host.pid)
    }

    /// Resolves the jump action for an agent kind and project path.
    package static func resolveAction(
        forKind kind: AgentKind,
        projectPath: String,
        processTreeSupplier: () -> String? = { Shell.run("/bin/ps", ["-axo", "pid=,ppid=,tty=,comm="]) },
        cwdSupplier: (Int) -> String? = { ProcessSnapshot.workingDirectory(of: $0) },
        bundleIdResolver: (String) -> String? = bundleIdentifier
    ) -> JumpAction {
        guard let output = processTreeSupplier() else {
            return .notFound
        }
        let tree = parseProcessTree(output)
        let candidates = findCandidateProcesses(for: kind, in: tree)
        guard let process = pickBestProcess(candidates: candidates, projectPath: projectPath, cwdSupplier: cwdSupplier) else {
            return .notFound
        }
        let host = findHostApp(for: process.pid, in: tree, bundleIdResolver: bundleIdResolver)
        return determineAction(host: host, tty: process.tty, projectPath: projectPath)
    }

    /// Executes the resolved jump action.
    package static func execute(_ action: JumpAction) {
        switch action {
        case .terminal(let script), .iterm(let script):
            _ = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 5)
        case .openProject(let bundleId, let path):
            _ = Shell.run("/usr/bin/open", ["-b", bundleId, path], timeout: 5)
        case .activateApp(let pid):
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: pid_t(pid))?.activate(options: .activateIgnoringOtherApps)
            }
        case .notFound:
            break
        }
    }
}
