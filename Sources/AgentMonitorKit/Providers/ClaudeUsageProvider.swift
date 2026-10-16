import Foundation

/// Claude plan limits (5-hour session, weekly) from the endpoint behind Claude Code's `/usage`.
/// Signs in with the OAuth token Claude Code keeps in the login Keychain; the token is only sent to Anthropic.
enum ClaudeUsageProvider {
    private struct Credentials {
        let token: String
        let expiresAt: Date?
        let plan: String?
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Nil when Claude Code is not set up on this Mac.
    static func fetch(now: Date = Date()) async throws -> PlanUsage? {
        guard AgentKind.claudeCode.isInstalled else { return nil }
        guard let credentials = readCredentials() else {
            throw UsageError(message: "Claude Code belum login dengan akun Claude, jadi usage paket tidak tersedia.")
        }
        if let expiry = credentials.expiresAt, expiry < now {
            throw UsageError(message: "Token login Claude Code kedaluwarsa. Jalankan Claude Code agar diperbarui.")
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let object = try await UsageError.fetchJSON(request, service: "Anthropic", agent: "Claude Code")
        return PlanUsage(kind: .claudeCode, plan: credentials.plan, limits: limits(in: object), fetchedAt: now)
    }

    /// `limits` lists every window with its share used; older replies only carry the named windows.
    private static func limits(in object: [String: Any]) -> [UsageLimit] {
        if let entries = object["limits"] as? [[String: Any]], !entries.isEmpty {
            return entries.enumerated().compactMap { index, entry in
                guard let used = entry["percent"] as? Double else { return nil }
                let kind = entry["kind"] as? String ?? ""
                let model = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                return UsageLimit(id: "\(index):\(kind)", kind: kind,
                                  title: title(kind: kind, group: entry["group"] as? String, model: model),
                                  used: used, resetsAt: ISODate.parse(entry["resets_at"] as? String))
            }
        }
        let named = [("five_hour", "session"), ("seven_day", "weekly_all"),
                     ("seven_day_opus", "weekly_opus"), ("seven_day_sonnet", "weekly_sonnet")]
        return named.compactMap { key, kind in
            guard let window = object[key] as? [String: Any], let used = window["utilization"] as? Double else { return nil }
            let model = key.hasPrefix("seven_day_") ? String(key.dropFirst("seven_day_".count)).capitalized : nil
            return UsageLimit(id: key, kind: kind, title: title(kind: kind, group: nil, model: model),
                              used: used, resetsAt: ISODate.parse(window["resets_at"] as? String))
        }
    }

    private static func title(kind: String, group: String?, model: String?) -> String {
        let base: String
        if kind == "session" || group == "session" {
            base = "Sesi 5 jam"
        } else if kind.hasPrefix("weekly") || group == "weekly" {
            base = "Mingguan"
        } else {
            base = kind
        }
        if let model { return "\(base) · \(model)" }
        return kind == "weekly_all" ? "Mingguan · semua model" : base
    }

    /// The Keychain item Claude Code writes on macOS, or the file it uses where there is no Keychain.
    /// It is read through `security`, which created the item, so no Keychain prompt appears.
    private static func readCredentials() -> Credentials? {
        let keychain = Shell.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        let file = try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json"), encoding: .utf8)
        for text in [keychain, file] {
            guard let data = text?.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = object["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String, !token.isEmpty else { continue }
            let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return Credentials(token: token, expiresAt: expiresAt,
                               plan: planName(subscription: oauth["subscriptionType"] as? String,
                                              tier: oauth["rateLimitTier"] as? String))
        }
        return nil
    }

    /// `team` + `default_claude_max_5x` → "Team · Max 5x".
    private static func planName(subscription: String?, tier: String?) -> String? {
        let multiplier = tier.flatMap { tier in
            tier.range(of: #"max_\d+x"#, options: .regularExpression)
                .map { tier[$0].replacingOccurrences(of: "max_", with: "Max ") }
        }
        switch (subscription.map(\.capitalized), multiplier) {
        case ("Max"?, let multiplier?): return multiplier
        case (let name?, let multiplier?): return "\(name) · \(multiplier)"
        case (let name?, nil): return name
        case (nil, let multiplier): return multiplier
        }
    }
}
