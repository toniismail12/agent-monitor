import Foundation

package enum Format {
    package static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total) dtk" }
        if total < 3600 { return "\(total / 60) mnt" }
        if total < 86_400 { return "\(total / 3600) jam \((total % 3600) / 60) mnt" }
        return "\(total / 86_400) hari \((total % 86_400) / 3600) jam"
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "id_ID")
        formatter.dateFormat = "HH.mm"
        return formatter
    }()

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "id_ID")
        formatter.dateFormat = "EEEE d MMM"
        return formatter
    }()

    /// "hari ini 13.19", "besok 06.59", "Senin 20 Okt 06.59".
    package static func moment(_ date: Date) -> String {
        let calendar = Calendar.current
        let day = calendar.isDateInToday(date) ? "hari ini"
            : calendar.isDateInTomorrow(date) ? "besok" : weekday.string(from: date)
        return "\(day) \(clock.string(from: date))"
    }

    package static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    package static func cost(_ usd: Double) -> String { String(format: "$%.2f", usd) }

    package static func snippet(_ text: String, limit: Int = 160) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    package static func folderName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    package static func relative(_ path: String, to base: String?) -> String {
        guard let base, path.hasPrefix(base + "/") else { return path }
        return String(path.dropFirst(base.count + 1))
    }
}

struct UsageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    /// Sends a usage request and turns the usual failures into messages for the panel.
    static func fetchJSON(_ request: URLRequest, service: String, agent: String) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError(message: "Tidak bisa menghubungi \(service): \(error.localizedDescription)")
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            break
        case 401, 403:
            throw UsageError(message: "Login \(agent) ditolak atau kedaluwarsa. Jalankan \(agent) agar login diperbarui.")
        case 429:
            throw UsageError(message: "Terlalu sering diminta. Dicoba lagi otomatis beberapa menit lagi.")
        case let code:
            throw UsageError(message: "\(service) membalas HTTP \(code).")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError(message: "Balasan usage \(agent) tidak bisa dibaca.")
        }
        return object
    }
}

extension AgentKind {
    /// Whether the agent is set up on this Mac, running or not.
    var isInstalled: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths: [String]
        switch self {
        case .claudeCode: paths = [home + "/.claude/projects"]
        case .codex: paths = [home + "/.codex/auth.json"]
        case .geminiCLI: paths = [home + "/.gemini/bin/agy"]
        case .geminiApp: paths = ["/Applications/Gemini.app"]
        case .copilot: paths = [home + "/.copilot"]
        case .claudeDesktop: paths = ["/Applications/Claude.app"]
        case .chatGPT: paths = ["/Applications/ChatGPT.app"]
        case .ollama: paths = ["/Applications/Ollama.app", "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
        }
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }
}

package enum ISODate {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    package static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        return fractional.date(from: text) ?? plain.date(from: text)
    }

    private static let local: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    /// "2026-10-16T14:50:29+07:00", like the timestamps Claude writes.
    package static func string(_ date: Date) -> String { local.string(from: date) }
}

enum FileScan {
    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func subdirectories(of root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    }

    /// Files with the given extension directly inside `directories`, modified within `window`.
    static func recentFiles(in directories: [URL], ext: String, within window: TimeInterval, now: Date) -> [String: Date] {
        var result: [String: Date] = [:]
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == ext {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(modified) < window else { continue }
                result[file.path] = modified
            }
        }
        return result
    }
}

/// Incrementally reads lines appended to a JSONL file. A large file is first read only from its tail.
package final class JSONLTail {
    package let path: String
    private let initialWindow: UInt64
    private var offset: UInt64?
    private var pending = Data()

    package init(path: String, initialWindow: UInt64 = 1_000_000) {
        self.path = path
        self.initialWindow = initialWindow
    }

    package func readNewLines() -> [Data] {
        guard let file = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0

        var skipPartialLine = false
        if offset == nil {
            offset = size > initialWindow ? size - initialWindow : 0
            skipPartialLine = offset != 0
        }
        guard var start = offset else { return [] }
        if size < start {  // truncated or replaced
            start = 0
            pending = Data()
        }
        guard size > start else { return [] }

        try? file.seek(toOffset: start)
        let data = file.readDataToEndOfFile()
        offset = start + UInt64(data.count)
        pending.append(data)

        var cursor = pending.startIndex
        if skipPartialLine, let newline = pending.firstIndex(of: 0x0A) {
            cursor = newline + 1
        }
        var lines: [Data] = []
        while let newline = pending[cursor...].firstIndex(of: 0x0A) {
            lines.append(pending.subdata(in: cursor..<newline))
            cursor = newline + 1
        }
        pending = pending.subdata(in: cursor..<pending.endIndex)
        return lines
    }

    /// True when the line declares one of the given `type` values near its start, so huge blobs can be skipped unparsed.
    package static func hasType(_ line: Data, in types: [String]) -> Bool {
        let head = String(decoding: line.prefix(120), as: UTF8.self)
        return types.contains { head.contains("\"type\":\"\($0)") }
    }
}

package struct ProcessEntry: Sendable {
    package let pid: Int
    package let elapsed: String
    package let cpu: Double
    package let memoryMB: Int
    package let path: String

    package init(pid: Int = 0, elapsed: String = "", cpu: Double = 0, memoryMB: Int = 0, path: String) {
        self.pid = pid
        self.elapsed = elapsed
        self.cpu = cpu
        self.memoryMB = memoryMB
        self.path = path
    }
}

enum ProcessSnapshot {
    static func capture() -> [ProcessEntry] {
        guard let output = Shell.run("/bin/ps", ["-axo", "pid=,etime=,%cpu=,rss=,comm="]) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5, let pid = Int(fields[0]), let cpu = Double(fields[2]),
                  let rss = Int(fields[3]) else { return nil }
            return ProcessEntry(pid: pid, elapsed: String(fields[1]), cpu: cpu, memoryMB: rss / 1024, path: String(fields[4]))
        }
    }

    /// Full command line; can contain newlines (multi-line prompts).
    static func arguments(of pid: Int) -> String {
        Shell.run("/bin/ps", ["-o", "args=", "-p", String(pid)]) ?? ""
    }

    /// Current working directory; for an agent CLI that is the project it works in.
    static func workingDirectory(of pid: Int) -> String? {
        guard let output = Shell.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]) else { return nil }
        return output.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }
}
