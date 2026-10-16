import AppKit
import SwiftUI
import AgentMonitorKit

@main
struct AgentMonitorApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        if CommandLine.arguments.contains("--agent-monitor-hook") {
            HookHandler.handleStandardInput()
            exit(0)
        }
        if CommandLine.arguments.contains("--dump") {
            MonitorModel.dump()
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MonitorView(model: delegate.model, panel: delegate.panel)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the model and the on-screen window, so the window can come back at launch without the menu being opened.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Lazy, so `--dump` exits before polling and notification setup start.
    lazy var model = MonitorModel()
    lazy var panel = FloatingPanel(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.restore()
    }
}
