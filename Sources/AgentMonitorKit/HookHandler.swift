import Foundation

/// Handles Claude Code hook invocations in `--agent-monitor-hook` mode,
/// recording permission events into ~/.agent-monitor/events.jsonl.
package enum HookHandler {
    package static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agent-monitor")
    package static let defaultEventsURL = defaultDirectory.appendingPathComponent("events.jsonl")

    /// Handles standard input in `--agent-monitor-hook` mode.
    /// Reads entire stdin and writes event record, printing nothing to stdout.
    package static func handleStandardInput() {
        let inputData = FileHandle.standardInput.readDataToEndOfFile()
        processInput(inputData)
    }

    /// Pure function for processing incoming hook payload data and recording it to events.jsonl.
    /// Returns true if a record was written, or false if input was invalid / not JSON.
    @discardableResult
    package static func processInput(
        _ data: Data,
        receivedAt: Date = Date(),
        directory: URL = defaultDirectory,
        maxFileSize: Int64 = 1_000_000
    ) -> Bool {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }

        var record: [String: Any] = [
            "received_at": ISODate.stringFractional(receivedAt)
        ]

        if let event = json["hook_event_name"] as? String {
            record["event"] = event
        }
        if let sessionId = json["session_id"] as? String {
            record["session_id"] = sessionId
        }
        if let cwd = json["cwd"] as? String {
            record["cwd"] = cwd
        }
        if let toolName = json["tool_name"] as? String {
            record["tool_name"] = toolName
        }
        if let notificationType = json["notification_type"] as? String {
            record["notification_type"] = notificationType
        }
        if let message = json["message"] as? String {
            record["message"] = message
        }
        if let toolInput = json["tool_input"] as? [String: Any] {
            let summary = Activity.summary(of: toolInput)
            if !summary.isEmpty {
                let flattened = summary.split(whereSeparator: \.isNewline)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                record["tool_summary"] = String(flattened.prefix(160))
            }
        }

        guard var lineData = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else {
            return false
        }
        lineData.append(0x0A) // '\n'

        let fileManager = FileManager.default
        let fileURL = directory.appendingPathComponent("events.jsonl")
        let rotatedURL = directory.appendingPathComponent("events.jsonl.1")

        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int64,
           size > maxFileSize {
            if fileManager.fileExists(atPath: rotatedURL.path) {
                try? fileManager.removeItem(at: rotatedURL)
            }
            try? fileManager.moveItem(at: fileURL, to: rotatedURL)
        }

        let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: lineData)
        } catch {
            return false
        }

        return true
    }
}
