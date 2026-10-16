import AppKit
import SwiftUI

/// The monitor as a window that stays on screen, alongside the menu bar popover.
@MainActor
package final class FloatingPanel: NSObject, ObservableObject, NSWindowDelegate {
    private static let frameName = "AgentMonitorPanel"

    @Published private(set) var isVisible = false
    @Published var alwaysOnTop: Bool {
        didSet {
            UserDefaults.standard.set(alwaysOnTop, forKey: "panelOnTop")
            window?.isFloatingPanel = alwaysOnTop
        }
    }

    private let model: MonitorModel
    private var window: NSPanel?

    package init(model: MonitorModel) {
        self.model = model
        alwaysOnTop = UserDefaults.standard.object(forKey: "panelOnTop") as? Bool ?? true
    }

    /// Reopens the window if it was on screen when the app last ran, and on the very first launch.
    package func restore() {
        if UserDefaults.standard.object(forKey: "panelVisible") as? Bool ?? true { show() }
    }

    func setVisible(_ visible: Bool) {
        if visible { show() } else { window?.close() }
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.orderFrontRegardless()
        remember(visible: true)
    }

    package func windowWillClose(_ notification: Notification) {
        remember(visible: false)
    }

    private func remember(visible: Bool) {
        isVisible = visible
        UserDefaults.standard.set(visible, forKey: "panelVisible")
    }

    private func makeWindow() -> NSPanel {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 540),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.title = "Agent Monitor"
        window.isFloatingPanel = alwaysOnTop
        // Stays visible while other apps are in front and on every Space; clicks do not take focus from them.
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self

        let host = NSHostingView(rootView: MonitorView(model: model, panel: self, inPanel: true))
        host.sizingOptions = [.minSize]
        window.contentView = host

        if !window.setFrameUsingName(Self.frameName), let area = NSScreen.main?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: area.maxX - window.frame.width - 16, y: area.maxY - 16))
        }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }
}
