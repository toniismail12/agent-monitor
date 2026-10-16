import Foundation

/// Tails an `agy --output-format stream-json` log and folds its events into activities.
package final class StreamReader {
    package private(set) var path: String?
    package private(set) var conversationId: String?
    package private(set) var model: String?
    package private(set) var resultStatus: String?
    package private(set) var resultError: String?
    package private(set) var lastEventAt: Date?
    package private(set) var totalTokens = 0

    private var offset: UInt64 = 0
    private var pending = Data()
    private var activities: [Int: Activity] = [:]
    private var order: [Int] = []
    /// A headless run that needs a permission it lacks is stopped, yet agy still reports SUCCESS.
    private var permissionDenied = false
    private var failedTool: String?

    package init() {}

    /// How the run ended, nil while it runs. A refused permission counts as a failure.
    package var outcome: (status: String, error: String?)? {
        guard let resultStatus else { return nil }
        guard permissionDenied else { return (resultStatus, resultError) }
        let what = failedTool.map { "Perintah `\($0)`" } ?? "Sebuah perintah"
        return ("DENIED", "\(what) tidak diizinkan. Izinkan di tab Loop, lalu kirim ulang.")
    }

    package func reset(path: String?) {
        self.path = path
        conversationId = nil
        model = nil
        resultStatus = nil
        resultError = nil
        lastEventAt = nil
        totalTokens = 0
        offset = 0
        pending = Data()
        activities = [:]
        order = []
        permissionDenied = false
        failedTool = nil
    }

    /// Reads whatever was appended since the last call. Returns true if anything changed.
    package func poll() -> Bool {
        guard let path, let file = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0
        if size < offset { reset(path: path) }
        guard size > offset else { return false }
        try? file.seek(toOffset: offset)
        let data = file.readDataToEndOfFile()
        offset += UInt64(data.count)
        pending.append(data)

        var changed = false
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.subdata(in: pending.startIndex..<newline)
            pending = pending.subdata(in: (newline + 1)..<pending.endIndex)
            if handle(line: line) { changed = true }
        }
        return changed
    }

    /// Newest first, without the empty "thinking" steps that already finished.
    package func visibleActivities(limit: Int = 60) -> [Activity] {
        let visible = order.reversed()
            .compactMap { activities[$0] }
            .filter { !($0.kind == .thinking && !$0.active) }
        return Array(visible.prefix(limit))
    }

    private func handle(line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = object["event"] as? String else {
            // agy explains a refused permission in a plain-text line, not in its JSON events.
            if String(decoding: line, as: UTF8.self).contains("auto-denied") { permissionDenied = true }
            return false
        }
        lastEventAt = Date()

        switch event {
        case "init":
            conversationId = object["conversation_id"] as? String
            model = (object["init"] as? [String: Any])?["model"] as? String
            return true
        case "result":
            let result = object["result"] as? [String: Any]
            resultStatus = result?["status"] as? String
            resultError = result?["error"] as? String
            return true
        case "step_update":
            guard let step = object["step_update"] as? [String: Any],
                  let index = step["step_index"] as? Int else { return false }
            return apply(step: step, index: index)
        default:
            return false
        }
    }

    private func apply(step: [String: Any], index: Int) -> Bool {
        let type = step["step_type"] as? String ?? ""
        if type == "user_input" { return false }

        var activity = activities[index] ?? Activity(id: index)
        if type == "tool" {
            let info = step["tool_info"] as? [String: Any]
            let name = step["tool_name"] as? String ?? info?["name"] as? String ?? "tool"
            let (kind, title) = Activity.describe(geminiTool: name)
            activity.kind = kind
            activity.title = title
            activity.detail = Activity.summary(of: info?["parameters"] as? [String: Any] ?? [:])
        } else if type == "agent_response" {
            if let delta = step["text_delta"] as? String, !delta.isEmpty {
                activity.kind = .response
                activity.title = "Menulis jawaban"
                activity.detail += delta
            } else if activity.detail.isEmpty {
                activity.kind = .thinking
                activity.title = "Berpikir"
            }
        } else {
            activity.title = type
        }

        let state = step["state"] as? String
        if type == "tool" && state == "ERROR" { failedTool = activity.detail }
        activity.active = state != "DONE" && state != "ERROR"
        if let duration = step["duration_seconds"] as? Double { activity.duration = duration }
        if let usage = step["usage"] as? [String: Any], let tokens = usage["total_tokens"] as? Int {
            totalTokens += tokens
        }
        if activities[index] == nil { order.append(index) }
        activities[index] = activity
        return true
    }
}
