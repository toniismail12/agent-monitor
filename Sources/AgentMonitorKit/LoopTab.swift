import AppKit
import SwiftUI

/// Runs the Claude ↔ Gemini loop from the panel: which project, where it stands, what Gemini may do, and its next task.
struct LoopTab: View {
    @ObservedObject var model: MonitorModel
    @AppStorage("loopModel") private var agyModel = "gemini-3.8-flash-high"
    @State private var prompt = ""
    @State private var phase = ""
    @State private var round = 1
    @State private var continueConversation = true
    @State private var newCommand = ""

    private var project: String? { model.loop?.state.project }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            projectRow
            if let project, let loop = model.loop {
                card {
                    LoopSection(loop: loop, model: model)
                    statusMenu
                }
                permissionsCard(project)
                taskCard(project)
            } else {
                Text("Belum ada loop. Pilih folder proyek untuk memulai.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.loopError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear(perform: syncFields)
        .onChange(of: project) { _ in syncFields() }
    }

    // MARK: - Project

    private var projectRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Proyek").font(.caption).foregroundStyle(.secondary)
                Menu {
                    ForEach(model.loopProjects, id: \.self) { path in
                        Button(Format.folderName(path) ?? path) { model.selectLoopProject(path) }
                    }
                    if !model.loopProjects.isEmpty { Divider() }
                    Button("Pilih folder…", action: chooseProject)
                } label: {
                    Text(Format.folderName(project) ?? "Pilih proyek").font(.callout.weight(.semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.loopRunning)
                .help(model.loopRunning ? "Tunggu putaran Gemini selesai sebelum berganti proyek" : project ?? "")
                Spacer()
            }
            if let project { fileChecks(project) }
        }
    }

    /// The files the loop works through; a missing one is the next thing to set up.
    private func fileChecks(_ project: String) -> some View {
        HStack(spacing: 10) {
            ForEach(["AGENTS.md", "HANDOFF.md", "REVIEW.md", ".git"], id: \.self) { name in
                let present = FileManager.default.fileExists(atPath: project + "/" + name)
                Label(name == ".git" ? "git" : name, systemImage: present ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(present ? Color.green : Color.secondary)
            }
        }
        .font(.caption2)
    }

    private var statusMenu: some View {
        HStack(spacing: 8) {
            Menu("Ubah status") {
                ForEach(LoopStatus.settable, id: \.self) { status in
                    Button(status.title) { model.setLoopStatus(status) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.loopRunning)
            Spacer()
            if let updated = ISODate.parse(model.loop?.state.updatedAt) {
                (Text("Diperbarui ") + Text(updated, style: .relative) + Text(" lalu"))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
    }

    // MARK: - Permissions

    @ViewBuilder
    private func permissionsCard(_ project: String) -> some View {
        card {
            header("Izin Gemini (agy)", symbol: "lock.shield")
            if let permissions = model.agyPermissions {
                HStack(spacing: 8) {
                    Text("Folder proyek").foregroundStyle(.secondary)
                    Spacer()
                    if permissions.canRead(project) && permissions.canWrite(project) {
                        Label("Boleh baca & tulis", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Cabut") { model.setAgyFolder(project, allowed: false) }
                    } else {
                        Text("Belum diizinkan").foregroundStyle(.orange)
                        Button("Izinkan baca & tulis") { model.setAgyFolder(project, allowed: true) }
                    }
                }
                Text("Perintah yang boleh dijalankan").foregroundStyle(.secondary)
                if permissions.commands.isEmpty {
                    Text("Belum ada. Gemini hanya bisa membaca dan mengedit file.").foregroundStyle(.tertiary)
                } else {
                    FlowLayout(spacing: 4) {
                        ForEach(permissions.commands, id: \.self) { commandChip($0) }
                    }
                }
                HStack(spacing: 6) {
                    TextField("Tambah perintah, mis. swift atau git status", text: $newCommand)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addCommand)
                    Button("Tambah", action: addCommand)
                        .disabled(newCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Berlaku untuk semua sesi agy. Versi sebelumnya disimpan sebagai settings.json.bak.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Label("settings.json agy tidak bisa dibaca, jadi izin tidak bisa diubah dari sini.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .controlSize(.small)
    }

    private func commandChip(_ command: String) -> some View {
        HStack(spacing: 3) {
            Text(command).font(.caption2.monospaced())
            Button {
                model.setAgyCommand(command, allowed: false)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Cabut izin \(command)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.08), in: Capsule())
    }

    private func addCommand() {
        model.setAgyCommand(newCommand, allowed: true)
        newCommand = ""
    }

    // MARK: - Task

    @ViewBuilder
    private func taskCard(_ project: String) -> some View {
        let allowed = model.agyPermissions.map { $0.canRead(project) && $0.canWrite(project) } ?? false
        let busy = model.loopRunning || model.loopSession?.state == .working
        let empty = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        card {
            header("Tugas untuk Gemini", symbol: "sparkles")
            HStack(spacing: 8) {
                Picker("Model", selection: $agyModel) {
                    ForEach(modelChoices, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                TextField("Tahap", text: $phase)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Stepper("Putaran \(round)", value: $round, in: 1...999).fixedSize()
            }
            if let conversation = model.loopConversation {
                Toggle("Lanjutkan percakapan \(conversation.prefix(8))…", isOn: $continueConversation)
                    .toggleStyle(.checkbox)
                    .help("Gemini membawa konteks putaran sebelumnya. Matikan untuk memulai percakapan baru.")
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $prompt)
                    .font(.caption.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 130)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
                if prompt.isEmpty {
                    Text("Tulis tugas untuk Gemini, atau muat dari file .md")
                        .foregroundStyle(.tertiary)
                        .padding(9)
                        .allowsHitTesting(false)
                }
            }
            if let session = model.loopSession, session.state == .working {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(session.activities.prefix(3)) { activity in
                        ActivityRow(activity: activity, detail: activity.kind == .response
                                    ? Format.snippet(activity.detail) : Format.relative(activity.detail, to: project))
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Muat file…", action: loadPrompt)
                Spacer()
                if model.loopRunning {
                    Button("Hentikan", role: .destructive, action: model.stopRound)
                } else {
                    Button("Kirim ke Gemini", action: send)
                        .disabled(!allowed || busy || empty)
                        .help(!allowed ? "Izinkan folder proyek untuk agy dulu"
                              : busy ? "Gemini masih bekerja" : "Jalankan agy -p di \(project)")
                }
            }
            Text("Berjalan headless dengan --mode accept-edits. Perintah di luar daftar izin ditolak dan sesinya berhenti.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .controlSize(.small)
    }

    /// The models agy offers, plus the chosen one in case the list has not been fetched yet.
    private var modelChoices: [(id: String, name: String)] {
        let choices = model.agyModelChoices
        return choices.contains { $0.id == agyModel } ? choices : [(agyModel, agyModel)] + choices
    }

    private func send() {
        model.startRound(prompt: prompt, model: agyModel, phase: phase, round: round,
                         continueConversation: continueConversation && model.loopConversation != nil)
        if model.loopRunning { prompt = "" }
    }

    /// The next round continues the phase the loop is in.
    private func syncFields() {
        let state = model.loop?.state
        phase = state?.phase ?? ""
        round = (state?.round ?? 0) + 1
    }

    // MARK: - Helpers

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Pakai untuk loop"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.selectLoopProject(url.path)
    }

    private func loadPrompt() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = project.map { URL(fileURLWithPath: $0) }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        prompt = text
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .font(.caption)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func header(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.callout.weight(.semibold))
        }
    }
}

/// Lays out its children in rows, starting a new row when the next child does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (subview, point) in zip(subviews, rows.points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (points, widest, y + rowHeight)
    }
}
