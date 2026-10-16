import Foundation

/// Codex plan limits from the endpoint behind Codex's `/status`, signed in with the ChatGPT login in ~/.codex/auth.json.
/// The token is only sent to OpenAI.
enum CodexUsageProvider {
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// Nil when Codex is not set up on this Mac.
    static func fetch(now: Date = Date()) async throws -> PlanUsage? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: path),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else {
            return PlanUsage(kind: .codex, plan: "API key",
                             note: "Codex memakai API key OpenAI, jadi tidak ada batas paket.", fetchedAt: now)
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let account = tokens["account_id"] as? String {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let object = try await UsageError.fetchJSON(request, service: "OpenAI", agent: "Codex")

        var limits = windows(object["rate_limit"] as? [String: Any], label: nil, now: now)
        limits += windows(object["code_review_rate_limit"] as? [String: Any], label: "Code review", now: now)
        for extra in object["additional_rate_limits"] as? [[String: Any]] ?? [] {
            let label = extra["limit_name"] as? String ?? extra["metered_feature"] as? String ?? "Lainnya"
            limits += windows(extra["rate_limit"] as? [String: Any], label: label, now: now)
        }

        var notes: [String] = []
        if (object["rate_limit"] as? [String: Any])?["limit_reached"] as? Bool == true {
            notes.append("Batas tercapai: Codex tidak bisa dipakai sampai reset.")
        }
        if let credits = object["credits"] as? [String: Any], credits["has_credits"] as? Bool == true {
            notes.append(credits["unlimited"] as? Bool == true
                         ? "Kredit tanpa batas."
                         : "Saldo kredit: \(credits["balance"].map { "\($0)" } ?? "-").")
        }
        return PlanUsage(kind: .codex, plan: (object["plan_type"] as? String)?.capitalized, limits: limits,
                         note: notes.isEmpty ? nil : notes.joined(separator: " "), fetchedAt: now)
    }

    private static func windows(_ rateLimit: [String: Any]?, label: String?, now: Date) -> [UsageLimit] {
        guard let rateLimit else { return [] }
        return ["primary_window", "secondary_window"].compactMap { key in
            guard let window = rateLimit[key] as? [String: Any], let used = window["used_percent"] as? Double else { return nil }
            let name = windowName(window["limit_window_seconds"] as? Double)
            let reset = (window["reset_at"] as? Double).map(Date.init(timeIntervalSince1970:))
                ?? (window["reset_after_seconds"] as? Double).map(now.addingTimeInterval)
            return UsageLimit(id: "\(label ?? ""):\(key)", kind: key, title: label.map { "\($0) · \(name)" } ?? name,
                              used: used, resetsAt: reset)
        }
    }

    /// 18000 → "Sesi 5 jam", 604800 → "Mingguan", 2592000 → "30 hari".
    private static func windowName(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "Batas" }
        let hours = Int((seconds / 3600).rounded())
        switch hours {
        case 5: return "Sesi 5 jam"
        case 168: return "Mingguan"
        case let hours where hours % 24 == 0: return "\(hours / 24) hari"
        default: return "\(hours) jam"
        }
    }
}
