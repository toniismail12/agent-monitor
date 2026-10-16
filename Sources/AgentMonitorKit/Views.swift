import AppKit
import SwiftUI

extension AgentState {
    var color: Color {
        switch self {
        case .waiting: return .orange
        case .working: return .blue
        case .failed: return .red
        case .finished: return .green
        case .idle, .running: return .secondary
        }
    }
}

extension LoopStatus {
    var color: Color {
        switch self {
        case .gemini: return .blue
        case .claude: return .orange
        case .done: return .green
        case .blocked: return .red
        case .idle, .none: return .secondary
        }
    }
}

package struct MenuBarLabel: View {
    @ObservedObject var model: MonitorModel

    package init(model: MonitorModel) {
        self.model = model
    }

    package var body: some View {
        if model.waitingCount > 0 {
            HStack(spacing: 3) {
                Image(systemName: "bell.badge.fill")
                Text("\(model.waitingCount)")
            }
        } else if model.workingCount > 0 {
            HStack(spacing: 3) {
                Image(systemName: "brain.head.profile")
                Text("\(model.workingCount)")
            }
        } else {
            Image(systemName: "brain")
        }
    }
}

enum MonitorTab: String, CaseIterable, Identifiable {
    case monitor, usage, models, loop

    var id: Self { self }

    var title: String {
        switch self {
        case .monitor: return "Monitor"
        case .usage: return "Usage"
        case .models: return "Model"
        case .loop: return "Loop"
        }
    }
}

package struct MonitorView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var panel: FloatingPanel
    /// In the on-screen window the list fills the window and the settings stay in the menu bar.
    var inPanel = false
    @State private var expanded: Set<String> = []
    /// Shared by the menu bar and the on-screen window.
    @AppStorage("tab") private var tab = MonitorTab.monitor

    package init(model: MonitorModel, panel: FloatingPanel, inPanel: Bool = false) {
        self.model = model
        self.panel = panel
        self.inPanel = inPanel
    }

    package var body: some View {
        if inPanel {
            content.frame(minWidth: 340, maxWidth: .infinity, minHeight: 280, maxHeight: .infinity, alignment: .top)
        } else {
            content.frame(width: 420)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            switch tab {
            case .monitor:
                agentList
                closeBar
                if let loop = model.visibleLoop {
                    Divider()
                    LoopSection(loop: loop, model: model)
                }
            case .usage:
                scrollable { UsageTab(model: model) }
            case .models:
                scrollable { ModelsTab(model: model) }
            case .loop:
                scrollable { LoopTab(model: model) }
            }
            if !inPanel {
                Divider()
                footer
            }
        }
        .padding(14)
        .onAppear { opened(tab) }
        .onChange(of: tab) { opened($0) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("Tampilan", selection: $tab) {
                ForEach(MonitorTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 8)
            headerDetail
            if inPanel {
                Button {
                    panel.alwaysOnTop.toggle()
                } label: {
                    Image(systemName: panel.alwaysOnTop ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(panel.alwaysOnTop ? "Selalu di atas jendela lain. Klik untuk melepas." : "Klik agar selalu di atas jendela lain")
            }
        }
    }

    @ViewBuilder
    private var headerDetail: some View {
        switch tab {
        case .monitor:
            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .usage:
            refreshButton(loading: model.usageLoading, help: "Perbarui usage sekarang") {
                model.refreshUsage(ifOlderThan: 15)
            }
        case .models:
            if AgentKind.geminiCLI.isInstalled {
                refreshButton(loading: model.modelsLoading, help: "Perbarui daftar model Gemini (agy)") {
                    model.refreshModels(force: true)
                }
            }
        case .loop:
            refreshButton(loading: model.modelsLoading, help: "Muat ulang izin agy dan daftar model Gemini") {
                model.refreshLoopControl()
                model.refreshModels(force: true)
            }
        }
    }

    private func refreshButton(loading: Bool, help: String, action: @escaping () -> Void) -> some View {
        Group {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Button(action: action) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(help)
            }
        }
    }

    /// Opening a tab refreshes what it shows when that is getting old.
    private func opened(_ tab: MonitorTab) {
        switch tab {
        case .monitor: break
        case .usage: model.refreshUsage(ifOlderThan: 60)
        case .models: model.refreshModels()
        case .loop:
            model.refreshLoopControl()
            model.refreshModels()
        }
    }

    /// The window scrolls its content; the menu bar popover grows to fit it.
    @ViewBuilder
    private func scrollable<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if inPanel {
            ScrollView { content().padding(.trailing, 6) }
                .frame(maxHeight: .infinity)
        } else {
            content()
        }
    }

    private var summary: String {
        var parts: [String] = []
        if model.waitingCount > 0 { parts.append("\(model.waitingCount) menunggu Anda") }
        if model.workingCount > 0 { parts.append("\(model.workingCount) bekerja") }
        let others = model.agents.count - model.waitingCount - model.workingCount
        if others > 0 { parts.append("\(others) lainnya") }
        return parts.isEmpty ? "Tidak ada agen aktif" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var agentList: some View {
        if model.agents.isEmpty {
            Text(model.dismissedAgents.isEmpty
                 ? "Tidak ada agen AI yang aktif dalam 30 menit terakhir."
                 : "Semua agen yang tersisa sudah ditutup. Agen muncul lagi saat aktif kembali.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 60, maxHeight: inPanel ? .infinity : nil)
        } else {
            let rows = VStack(alignment: .leading, spacing: 8) {
                ForEach(model.agents) { agent in
                    AgentRow(agent: agent, expanded: binding(for: agent.id), model: model)
                }
            }
            if inPanel {
                ScrollView { rows.padding(.trailing, 6) }
                    .frame(maxHeight: .infinity)
            } else if model.agents.count > 4 || !expanded.isEmpty {
                ScrollView { rows.padding(.trailing, 6) }
                    .frame(height: 430)
            } else {
                rows
            }
        }
    }

    /// Bulk close for finished and quiet agents, and a way back to the ones already closed.
    @ViewBuilder
    private var closeBar: some View {
        let closable = model.dismissableCount
        if closable > 0 || !model.dismissedAgents.isEmpty {
            HStack(spacing: 8) {
                if !model.dismissedAgents.isEmpty {
                    Menu {
                        Section("Pantau lagi") {
                            ForEach(model.dismissedAgents) { agent in
                                Button("\(agent.kind.name) · \(agent.title) (\(agent.state.label))") {
                                    model.undismiss(agent.id)
                                }
                            }
                        }
                        Divider()
                        Button("Tampilkan semua lagi") { model.undismissAll() }
                    } label: {
                        Label("\(model.dismissedAgents.count) ditutup", systemImage: "eye.slash")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Agen yang ditutup dari pantauan. Pilih untuk memantaunya lagi.")
                }
                Spacer()
                if closable > 0 {
                    Button {
                        model.dismissInactive()
                    } label: {
                        Label("Tutup yang selesai & diam (\(closable))", systemImage: "xmark.circle")
                    }
                    .help("Berhenti memantau agen yang sudah selesai atau tidak ada aktivitas. Agen muncul lagi saat aktif kembali.")
                }
            }
            .font(.caption)
            .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Notifikasi", isOn: $model.notificationsOn)
                .toggleStyle(.checkbox)
            Toggle("Jalan saat login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            Toggle("Tampil di layar", isOn: Binding(
                get: { panel.isVisible },
                set: { panel.setVisible($0) }
            ))
            .toggleStyle(.checkbox)
            .help("Tampilkan monitor sebagai jendela yang tetap di layar")
            Spacer()
            Button("Keluar") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
        .font(.caption)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOn in
                if isOn { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }
}

struct AgentRow: View {
    let agent: AgentSession
    @Binding var expanded: Bool
    let model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    summary
                }
                .buttonStyle(.plain)
                if agent.canDismiss {
                    Button {
                        model.dismiss(agent.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Tutup pantauan agen ini. Agen muncul lagi saat aktif kembali.")
                }
            }
            if expanded { details }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(agent.state == .waiting ? Color.orange.opacity(0.12) : Color.primary.opacity(0.05))
        )
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: agent.kind.symbol)
                .font(.callout)
                .foregroundStyle(agent.state.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(agent.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    StatePill(state: agent.state)
                }
                meta
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !agent.detail.isEmpty {
                    Text(agent.detail)
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var meta: Text {
        var text = Text(agent.kind.name)
        if let folder = Format.folderName(agent.project), folder != agent.title {
            text = text + Text(" · \(folder)")
        }
        if let last = agent.lastActivity {
            text = text + Text(" · ") + Text(last, style: .relative) + Text(" lalu")
        }
        if let cost = agent.costUSD {
            text = text + Text(" · \(Format.cost(cost))")
        } else if let tokens = agent.tokens {
            text = text + Text(" · \(tokens.formatted()) token")
        }
        if agent.lastActivity == nil, let cpu = agent.cpu, let memory = agent.memoryMB {
            text = text + Text(String(format: " · CPU %.0f%% · %d MB", cpu, memory))
        }
        return text
    }

    @ViewBuilder
    private var details: some View {
        if agent.activities.isEmpty {
            Text(agent.state == .running ? "Aplikasi ini tidak menyediakan detail aktivitas." : "Belum ada aktivitas tercatat.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 30)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(agent.activities.prefix(10)) { activity in
                    ActivityRow(activity: activity, detail: detail(for: activity))
                }
            }
            .padding(.leading, 30)
        }
        if agent.logPath != nil || agent.project != nil {
            HStack(spacing: 6) {
                if let log = agent.logPath { Button("Log") { model.openLog(log) } }
                if let project = agent.project { Button("Folder") { model.open(project) } }
            }
            .controlSize(.small)
            .padding(.leading, 30)
        }
    }

    private func detail(for activity: Activity) -> String {
        activity.kind == .response || activity.kind == .prompt
            ? Format.snippet(activity.detail)
            : Format.relative(activity.detail, to: agent.project)
    }
}

struct StatePill: View {
    let state: AgentState

    var body: some View {
        Text(state.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(state.color.opacity(0.15), in: Capsule())
            .foregroundStyle(state.color)
    }
}

struct ActivityRow: View {
    let activity: Activity
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: activity.kind.symbol)
                .font(.caption)
                .foregroundStyle(activity.active ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.title).font(.caption.weight(.semibold))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if activity.active {
                ProgressView().controlSize(.mini)
            } else if let duration = activity.duration {
                Text(duration < 1 ? "<1 dtk" : Format.duration(duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension UsageLimit {
    var color: Color { used >= 90 ? .red : used >= 75 ? .orange : .blue }
}

/// Plan limits of every agent on this Mac: how much is used and left, and when it resets.
struct UsageTab: View {
    @ObservedObject var model: MonitorModel

    private struct Missing {
        let kind: AgentKind
        let title: String
        let reason: String
    }

    /// Agents whose limits cannot be read on this Mac, with what to do instead.
    private static let missing = [
        Missing(kind: .geminiCLI, title: "Gemini CLI (agy)", reason: "kuota per model belum didukung; lihat di Antigravity."),
        Missing(kind: .geminiApp, title: "Aplikasi Gemini", reason: "Google tidak menyimpan data batas di perangkat."),
        Missing(kind: .copilot, title: "GitHub Copilot", reason: "lihat kuota lewat ikon Copilot di status bar VS Code."),
        Missing(kind: .claudeDesktop, title: "Aplikasi Claude", reason: "memakai batas akun Claude, sama dengan Claude Code bila akunnya sama."),
        Missing(kind: .chatGPT, title: "Aplikasi ChatGPT", reason: "OpenAI tidak menyediakan data batas chat; batas Codex ada di atas."),
        Missing(kind: .ollama, title: "Ollama", reason: "model lokal, tanpa batas."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let cards = MonitorModel.usageKinds.compactMap { model.usage[$0] }
            ForEach(cards, id: \.kind) { UsageCard(usage: $0) }
            if cards.isEmpty {
                Text(model.usageLoading ? "Memuat usage…" : "Belum ada agent yang batas paketnya bisa dibaca.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let others = Self.missing.filter { $0.kind.isInstalled }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tanpa data usage").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(others, id: \.kind) { other in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: other.kind.symbol).foregroundStyle(.secondary).frame(width: 16)
                            Text(other.title).fontWeight(.semibold) + Text(" — \(other.reason)").foregroundColor(.secondary)
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 4)
            }
            if let checked = model.usageCheckedAt {
                (Text("Diperbarui ") + Text(checked, style: .relative) + Text(" lalu · otomatis tiap 5 menit"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct UsageCard: View {
    let usage: PlanUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: usage.kind.symbol).font(.callout).foregroundStyle(.secondary).frame(width: 20)
                Text(usage.kind.name).font(.callout.weight(.semibold))
                Spacer()
                if let plan = usage.plan {
                    Text(plan)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(usage.limits) { UsageLimitRow(limit: $0) }
            if usage.limits.isEmpty && usage.note == nil && usage.error == nil {
                Text("Tidak ada batas yang dilaporkan.").font(.caption).foregroundStyle(.secondary)
            }
            if let note = usage.note {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(usage.limits.contains { $0.used >= 100 } ? Color.red : Color.secondary)
            }
            if let error = usage.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

struct UsageLimitRow: View {
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(limit.title).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Format.percent(limit.used)) terpakai")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(limit.color)
                Text("· \(Format.percent(limit.remaining)) tersisa")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(limit.color)
                        .frame(width: geometry.size.width * min(max(limit.used, 0), 100) / 100)
                }
            }
            .frame(height: 6)
            if let reset = limit.resetsAt {
                Text(resetText(reset))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resetText(_ reset: Date) -> String {
        let left = reset.timeIntervalSinceNow
        return left > 0
            ? "Reset \(Format.moment(reset)) · \(Format.duration(left)) lagi"
            : "Sudah reset, menunggu data baru"
    }
}

/// The model each agent is set to, the ones its sessions use, and the ones it offers.
struct ModelsTab: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let agents = model.models
            ForEach(agents) { ModelCard(agent: $0) }
            if agents.isEmpty {
                Text("Tidak ada agent CLI yang terpasang.").font(.caption).foregroundStyle(.secondary)
            }
            let apps = [AgentKind.claudeDesktop, .chatGPT, .geminiApp, .copilot].filter(\.isInstalled).map(\.name)
            if !apps.isEmpty {
                Text("Model di \(apps.joined(separator: ", ")) dipilih langsung di aplikasinya dan tidak tercatat di perangkat.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct ModelCard: View {
    let agent: AgentModels

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: agent.kind.symbol).font(.callout).foregroundStyle(.secondary).frame(width: 20)
                Text(agent.title).font(.callout.weight(.semibold))
            }
            if let configured = agent.configured {
                row("Bawaan") { Text(configured) }
            }
            // Ollama runs models for other apps, so it has no sessions of its own here.
            if agent.kind != .ollama {
                row("Dipakai") {
                    if agent.inUse.isEmpty {
                        Text("Tidak ada sesi aktif").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(agent.inUse) { use in
                                Text(use.model).fontWeight(.semibold)
                                    + Text(" · " + use.sessions.joined(separator: ", ")).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            row("Tersedia") {
                Text(agent.available.isEmpty ? "Belum diketahui" : agent.available.joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            value().fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct LoopSection: View {
    let loop: LoopSnapshot
    let model: MonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: loop.status.symbol).foregroundStyle(loop.status.color)
                Text("Loop \(Format.folderName(loop.state.project) ?? ""): \(loop.status.title)")
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            if !loop.subtitle.isEmpty {
                Text(loop.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                chip("Terbuka", loop.review.open, .red)
                chip("Diperbaiki", loop.review.fixed, .green)
                chip("Ditolak", loop.review.rejected, .orange)
                Spacer()
                Text(loop.changes.isEmpty ? "Tidak ada perubahan" : "\(loop.changes.count) file berubah")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let project = loop.state.project {
                HStack(spacing: 6) {
                    Button("HANDOFF.md") { model.open(project + "/HANDOFF.md") }
                    Button("REVIEW.md") { model.open(project + "/REVIEW.md") }
                    Button("Folder") { model.open(project) }
                }
                .controlSize(.small)
            }
        }
    }

    private func chip(_ label: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(count)").font(.caption.weight(.bold)).monospacedDigit()
            Text(label).font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(count > 0 ? 0.15 : 0.06), in: Capsule())
        .foregroundStyle(count > 0 ? color : Color.secondary)
    }
}
