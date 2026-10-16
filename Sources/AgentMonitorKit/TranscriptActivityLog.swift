import Foundation

/// Shared activity log for transcript-based providers (Claude Code, Codex).
/// Tracks activities, manages open tool calls and durations, caps history at 80 items,
/// and prepares the most recent 30 items for display.
package final class TranscriptActivityLog {
    package private(set) var activities: [Activity] = []
    package private(set) var openTools: [String: Int] = [:]
    private var nextId = 0

    package init() {}

    /// The latest active activity among currently open tools, if any.
    package var runningActivity: Activity? {
        openTools.isEmpty ? nil : activities.last(where: \.active)
    }

    /// Appends a new activity to the log. If `toolId` is provided, tracks it as an open tool call.
    /// Activity detail is trimmed to 300 characters via `Format.snippet`.
    /// Total activities are capped at 80, dropping the oldest when exceeded.
    @discardableResult
    package func append(
        _ kind: Activity.Kind,
        _ title: String,
        _ detail: String,
        active: Bool = false,
        at time: Date? = nil,
        toolId: String? = nil
    ) -> Int {
        nextId += 1
        activities.append(Activity(
            id: nextId,
            kind: kind,
            title: title,
            detail: Format.snippet(detail, limit: 300),
            active: active,
            startedAt: time ?? Date()
        ))
        if activities.count > 80 {
            activities.removeFirst(activities.count - 80)
        }
        if let toolId {
            openTools[toolId] = nextId
        }
        return nextId
    }

    /// Marks an open tool call as finished and computes its duration.
    /// Closing an unknown id or closing the same id more than once has no effect.
    package func closeTool(_ id: String, at time: Date? = nil) {
        guard let activityId = openTools.removeValue(forKey: id),
              let index = activities.firstIndex(where: { $0.id == activityId }) else { return }
        activities[index].active = false
        if let time {
            activities[index].duration = time.timeIntervalSince(activities[index].startedAt)
        }
    }

    /// The activities to display: up to 30 most recent in reverse order.
    /// Forces `active = false` on all returned activities if the session state is not `.working`.
    package func visibleActivities(for state: AgentState, limit: Int = 30) -> [Activity] {
        var shown = Array(activities.suffix(limit).reversed())
        if state != .working {
            for index in shown.indices {
                shown[index].active = false
            }
        }
        return shown
    }
}
