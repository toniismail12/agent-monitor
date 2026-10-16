import Foundation

/// The Claude ↔ Gemini review loop (first built for the Aegis project): its state file, review findings and pending changes.
package final class AegisLoop {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aegis-loop")

    private var snapshot: LoopSnapshot?
    private var tick = 0

    package init() {}

    func refresh() -> LoopSnapshot? {
        tick += 1
        let url = Self.directory.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(LoopState.self, from: data) else { return nil }
        var next = snapshot ?? LoopSnapshot(state: state)
        next.state = state
        // git and REVIEW.md change slowly; every third tick is enough, unless the loop moved to another project.
        if let project = state.project, tick % 3 == 1 || snapshot?.state.project != project {
            (next.changes, next.diffSummary) = Self.changes(in: project)
            next.review = Self.reviewCounts(in: project)
        }
        snapshot = next
        return next
    }

    /// Working-tree changes against the index, which Claude uses as the review baseline.
    private static func changes(in project: String) -> ([ChangedFile], String) {
        guard let output = Shell.run("/usr/bin/git", ["-C", project, "status", "--porcelain"]) else { return ([], "") }
        var files: [ChangedFile] = []
        for line in output.split(separator: "\n") where line.count > 3 {
            let chars = Array(line)
            let path = String(chars[3...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if chars[0] == "?" && chars[1] == "?" {
                files.append(ChangedFile(status: "baru", path: path))
            } else if chars[1] != " " {
                files.append(ChangedFile(status: chars[1] == "D" ? "hapus" : "ubah", path: path))
            }
        }
        let stat = Shell.run("/usr/bin/git", ["-C", project, "diff", "--shortstat"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (files, stat)
    }

    /// Counts finding statuses in the "Putaran terbaru" part of REVIEW.md.
    package static func reviewCounts(in project: String) -> ReviewCounts {
        let url = URL(fileURLWithPath: project).appendingPathComponent("REVIEW.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"\*\*Status:\*\*\s*`?(Terbuka|Diperbaiki|Ditolak)"#)
        else { return ReviewCounts() }
        let current = text.components(separatedBy: "\n## Riwayat").first ?? text
        let ns = current as NSString
        var counts = ReviewCounts()
        for match in regex.matches(in: current, range: NSRange(location: 0, length: ns.length)) {
            switch ns.substring(with: match.range(at: 1)) {
            case "Terbuka": counts.open += 1
            case "Diperbaiki": counts.fixed += 1
            default: counts.rejected += 1
            }
        }
        return counts
    }
}
