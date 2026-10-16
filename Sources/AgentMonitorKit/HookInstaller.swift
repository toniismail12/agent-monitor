import Foundation

/// Manages installation, uninstallation, and status of Claude Code hooks in ~/.claude/settings.json.
package struct HookInstaller {
    package static let defaultSettingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    package enum Status: Equatable, Sendable {
        case installed
        case notInstalled
        case disabled
    }

    package enum InstallError: LocalizedError, Equatable {
        case notInAppBundle
        case unparseableSettings
        case writeFailed(String)

        package var errorDescription: String? {
            switch self {
            case .notInAppBundle:
                return "Aplikasi harus dijalankan dari bundle .app (bukan swift run) untuk memasang hook."
            case .unparseableSettings:
                return "File settings.json tidak dapat dibaca sebagai JSON yang valid."
            case .writeFailed(let msg):
                return "Gagal menyimpan konfigurasi hook: \(msg)"
            }
        }
    }

    /// Checks if a bundle is an application bundle (.app).
    package static func isAppBundle(_ bundle: Bundle = .main) -> Bool {
        bundle.bundleURL.pathExtension == "app" || bundle.bundlePath.hasSuffix(".app")
    }

    /// Formats the command string for the given executable path.
    package static func command(for executablePath: String) -> String {
        let escaped = executablePath.replacingOccurrences(of: "'", with: "'\\''")
        return "[ -x '\(escaped)' ] && '\(escaped)' --agent-monitor-hook || true"
    }

    /// Inspects the settings file at the given URL to determine current hook status.
    package static func status(settingsURL: URL = defaultSettingsURL) -> Status {
        guard FileManager.default.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .notInstalled
        }
        return status(in: dict)
    }

    /// Inspects a settings dictionary to determine current hook status.
    package static func status(in settings: [String: Any]) -> Status {
        if settings["disableAllHooks"] as? Bool == true {
            return .disabled
        }
        guard let hooks = settings["hooks"] as? [String: Any] else {
            return .notInstalled
        }
        let hasPerm = hasOurHook(in: hooks["PermissionRequest"])
        let hasNotif = hasOurHook(in: hooks["Notification"])
        return (hasPerm && hasNotif) ? .installed : .notInstalled
    }

    private static func hasOurHook(in matcherListAny: Any?) -> Bool {
        guard let matcherList = matcherListAny as? [[String: Any]] else { return false }
        for matcher in matcherList {
            guard let hookList = matcher["hooks"] as? [[String: Any]] else { continue }
            for hook in hookList {
                if let cmd = hook["command"] as? String, cmd.contains("--agent-monitor-hook") {
                    return true
                }
            }
        }
        return false
    }

    /// Pure function to install hooks into a settings dictionary. Idempotent.
    package static func install(in settings: [String: Any], executablePath: String) -> [String: Any] {
        var cleanSettings = uninstall(from: settings)
        var hooks = cleanSettings["hooks"] as? [String: Any] ?? [:]

        let cmd = command(for: executablePath)
        let ourHookEntry: [String: Any] = ["type": "command", "command": cmd]

        // 1. PermissionRequest with matcher ""
        hooks["PermissionRequest"] = addHook(
            to: hooks["PermissionRequest"] as? [[String: Any]] ?? [],
            matcherString: "",
            hookEntry: ourHookEntry
        )

        // 2. Notification with matcher "permission_prompt"
        hooks["Notification"] = addHook(
            to: hooks["Notification"] as? [[String: Any]] ?? [],
            matcherString: "permission_prompt",
            hookEntry: ourHookEntry
        )

        cleanSettings["hooks"] = hooks
        return cleanSettings
    }

    private static func addHook(
        to matchers: [[String: Any]],
        matcherString: String,
        hookEntry: [String: Any]
    ) -> [[String: Any]] {
        var result = matchers
        if let index = result.firstIndex(where: { ($0["matcher"] as? String) == matcherString }) {
            var matcher = result[index]
            var hookList = matcher["hooks"] as? [[String: Any]] ?? []
            hookList.append(hookEntry)
            matcher["hooks"] = hookList
            result[index] = matcher
        } else {
            result.append([
                "matcher": matcherString,
                "hooks": [hookEntry]
            ])
        }
        return result
    }

    /// Pure function to uninstall our hooks from a settings dictionary, cleaning empty containers
    /// only when they became empty because our hook was removed.
    package static func uninstall(from settings: [String: Any]) -> [String: Any] {
        guard let hooks = settings["hooks"] as? [String: Any] else {
            return settings
        }

        let hadOurHookAnywhere = hooks.values.contains { hasOurHook(in: $0) }
        guard hadOurHookAnywhere else {
            return settings
        }

        var newHooks: [String: Any] = [:]
        for (event, matchersAny) in hooks {
            guard let matchers = matchersAny as? [[String: Any]] else {
                newHooks[event] = matchersAny
                continue
            }
            if !hasOurHook(in: matchers) {
                // Event never contained our hook; preserve container as-is even if empty
                newHooks[event] = matchersAny
                continue
            }

            var newMatchers: [[String: Any]] = []
            for matcher in matchers {
                guard let hookList = matcher["hooks"] as? [[String: Any]] else {
                    newMatchers.append(matcher)
                    continue
                }
                let hadOurHook = hookList.contains { hook in
                    (hook["command"] as? String)?.contains("--agent-monitor-hook") == true
                }
                if !hadOurHook {
                    newMatchers.append(matcher)
                    continue
                }

                let filteredHooks = hookList.filter { hook in
                    guard let cmd = hook["command"] as? String else { return true }
                    return !cmd.contains("--agent-monitor-hook")
                }
                if !filteredHooks.isEmpty {
                    var newMatcher = matcher
                    newMatcher["hooks"] = filteredHooks
                    newMatchers.append(newMatcher)
                }
            }

            if !newMatchers.isEmpty {
                newHooks[event] = newMatchers
            }
        }

        var result = settings
        if newHooks.isEmpty {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = newHooks
        }
        return result
    }

    /// Installs hooks into the settings file at `settingsURL`.
    package static func install(
        settingsURL: URL = defaultSettingsURL,
        executablePath: String? = nil,
        bundle: Bundle = .main
    ) throws {
        let execPath: String
        if let executablePath {
            execPath = executablePath
        } else {
            guard isAppBundle(bundle), let path = bundle.executablePath else {
                throw InstallError.notInAppBundle
            }
            execPath = path
        }

        let targetURL = settingsURL.resolvingSymlinksInPath()
        var settings: [String: Any] = [:]
        let fileManager = FileManager.default
        let fileExists = fileManager.fileExists(atPath: targetURL.path)

        if fileExists {
            guard let data = try? Data(contentsOf: targetURL),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw InstallError.unparseableSettings
            }
            settings = json
        }

        let updated = install(in: settings, executablePath: execPath)
        try writeSettings(updated, to: targetURL, createBackup: fileExists)
    }

    /// Uninstalls our hooks from the settings file at `settingsURL`.
    package static func uninstall(
        settingsURL: URL = defaultSettingsURL
    ) throws {
        let targetURL = settingsURL.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: targetURL.path) else {
            return
        }

        guard let data = try? Data(contentsOf: targetURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InstallError.unparseableSettings
        }

        let updated = uninstall(from: json)
        if NSDictionary(dictionary: json).isEqual(to: updated) {
            return
        }
        try writeSettings(updated, to: targetURL, createBackup: true)
    }

    private static func writeSettings(_ settings: [String: Any], to url: URL, createBackup: Bool) throws {
        let targetURL = url.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if createBackup && fileManager.fileExists(atPath: targetURL.path) {
            let backupURL = URL(fileURLWithPath: targetURL.path + ".agent-monitor.bak")
            if fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.removeItem(at: backupURL)
            }
            do {
                try fileManager.copyItem(at: targetURL, to: backupURL)
            } catch {
                throw InstallError.writeFailed("Gagal membuat backup: \(error.localizedDescription)")
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            throw InstallError.writeFailed("Gagal serialisasi JSON")
        }

        do {
            try data.write(to: targetURL, options: .atomic)
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }
}
