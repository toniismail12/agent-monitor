import Foundation
import AgentMonitorKit

// MARK: - Test Framework Helpers

private var totalAssertions = 0
private var failedAssertions = 0

private func check(_ condition: Bool, _ description: String, file: StaticString = #filePath, line: UInt = #line) {
    totalAssertions += 1
    if !condition {
        failedAssertions += 1
        print("  ❌ Gagal: \(description) (\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line))")
    }
}

private func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ description: String, file: StaticString = #filePath, line: UInt = #line) {
    totalAssertions += 1
    if actual != expected {
        failedAssertions += 1
        print("  ❌ Gagal: \(description). Diharapkan: '\(expected)', didapat: '\(actual)' (\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line))")
    }
}

private func runSuite(_ name: String, _ body: () throws -> Void) {
    let startFailures = failedAssertions
    print("▶ Menguji \(name)...")
    do {
        try body()
        if failedAssertions == startFailures {
            print("  ✓ \(name): Lolos")
        }
    } catch {
        failedAssertions += 1
        print("  ❌ Exception tidak terduga pada \(name): \(error)")
    }
}

private func resolveFixturesDirectory() -> URL {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let candidate = cwd.appendingPathComponent("Tests/Fixtures")
    if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
    }
    let fileAnchor = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // AgentMonitorChecks
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // Root
        .appendingPathComponent("Tests/Fixtures")
    if FileManager.default.fileExists(atPath: fileAnchor.path) {
        return fileAnchor
    }
    fatalError("Direktori fixture Tests/Fixtures tidak ditemukan di \(candidate.path) maupun \(fileAnchor.path)")
}

// MARK: - Test Suites

func testFormatAndDates() {
    // Format duration
    checkEqual(Format.duration(0), "0 dtk", "Duration 0 detik")
    checkEqual(Format.duration(45), "45 dtk", "Duration 45 detik")
    checkEqual(Format.duration(120), "2 mnt", "Duration 120 detik (2 menit)")
    checkEqual(Format.duration(3665), "1 jam 1 mnt", "Duration 3665 detik (1 jam 1 menit)")
    checkEqual(Format.duration(90000), "1 hari 1 jam", "Duration 90000 detik (1 hari 1 jam)")

    // Format currency & percent
    checkEqual(Format.cost(0.05), "$0.05", "Cost dua desimal pembulatan")
    checkEqual(Format.cost(12.5), "$12.50", "Cost dua desimal")
    checkEqual(Format.percent(88.6), "89%", "Percent pembulatan")

    // Format text
    checkEqual(Format.snippet("Halo\ndunia\npanjang sekali", limit: 10), "Halo dunia…", "Snippet pemangkasan teks")
    checkEqual(Format.folderName("/Users/dev/contoh-proyek"), "contoh-proyek", "Folder name extraction")
    checkEqual(Format.folderName(nil), nil, "Folder name nil")
    checkEqual(Format.relative("/Users/dev/contoh-proyek/Sources/App.swift", to: "/Users/dev/contoh-proyek"), "Sources/App.swift", "Relative path")

    // ISODate parsing
    let fractionalDate = ISODate.parse("2026-10-16T10:00:00.000Z")
    check(fractionalDate != nil, "ISODate parse format ISO fractional")
    let plainDate = ISODate.parse("2026-10-16T10:00:00Z")
    check(plainDate != nil, "ISODate parse format ISO plain")
    check(ISODate.parse(nil) == nil, "ISODate parse nil")

    if let fractionalDate {
        let formattedStr = ISODate.string(fractionalDate)
        check(!formattedStr.isEmpty, "ISODate string formatting")
    }
}

func testJSONLTail() throws {
    // 1. Pembacaan inkremental dan penahanan baris tak lengkap
    let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("tail_test_\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    let initialContent = "{\"line\":1}\n{\"line\":2}\n"
    try initialContent.data(using: .utf8)?.write(to: tmpFile)

    let tail = JSONLTail(path: tmpFile.path)
    let firstLines = tail.readNewLines()
    checkEqual(firstLines.count, 2, "JSONLTail membaca 2 baris awal")

    // Append baris baru
    let appendHandle = try FileHandle(forWritingTo: tmpFile)
    try appendHandle.seekToEnd()
    appendHandle.write(Data("{\"line\":3}\n".utf8))
    try appendHandle.close()

    let secondLines = tail.readNewLines()
    checkEqual(secondLines.count, 1, "JSONLTail membaca 1 baris yang baru ditambahkan")
    if let line3 = secondLines.first {
        checkEqual(String(decoding: line3, as: UTF8.self), "{\"line\":3}", "Konten baris ke-3 sesuai")
    }

    // Append potongan baris tanpa newline lalu lengkapi
    let appendHandle2 = try FileHandle(forWritingTo: tmpFile)
    try appendHandle2.seekToEnd()
    appendHandle2.write(Data("{\"line\":4_part".utf8))
    try appendHandle2.close()

    let partialLines = tail.readNewLines()
    checkEqual(partialLines.count, 0, "JSONLTail menahan potongan baris tanpa newline")

    let appendHandle3 = try FileHandle(forWritingTo: tmpFile)
    try appendHandle3.seekToEnd()
    appendHandle3.write(Data("ial\"}\n".utf8))
    try appendHandle3.close()

    let completedLines = tail.readNewLines()
    checkEqual(completedLines.count, 1, "JSONLTail membaca baris yang sudah lengkap dengan newline")
    if let line4 = completedLines.first {
        checkEqual(String(decoding: line4, as: UTF8.self), "{\"line\":4_partial\"}", "Konten baris sambungan sesuai")
    }

    // 2. Pembacaan dari ekor file dengan window kecil (memotong di tengah baris)
    let windowFile = FileManager.default.temporaryDirectory.appendingPathComponent("tail_window_\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: windowFile) }
    // Line 1: 20 byte, Line 2: 20 byte, Line 3: 21 byte. Total = 61 byte.
    let windowContent = "baris_awal_dipotong\nbaris_kedua_lengkap\nbaris_ketiga_lengkap\n"
    try windowContent.data(using: .utf8)?.write(to: windowFile)

    // initialWindow 30 membuat offset berada di byte 31 (di tengah baris kedua, offset 20..<40).
    let tailWindow = JSONLTail(path: windowFile.path, initialWindow: 30)
    let windowLines = tailWindow.readNewLines()
    checkEqual(windowLines.count, 1, "Window kecil membuang potongan baris awal (skipPartialLine) dan membaca baris utuh berikutnya")
    if let first = windowLines.first {
        checkEqual(String(decoding: first, as: UTF8.self), "baris_ketiga_lengkap", "Konten baris utuh setelah potongan sesuai")
    }

    // 3. File yang dipotong atau diganti dengan isi yang lebih pendek (size < start)
    let truncFile = FileManager.default.temporaryDirectory.appendingPathComponent("tail_trunc_\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: truncFile) }
    let initialTrunc = "baris_awal_1\nbaris_awal_2\n" // 26 byte
    try initialTrunc.data(using: .utf8)?.write(to: truncFile)
    let tailTrunc = JSONLTail(path: truncFile.path)
    let initialTruncLines = tailTrunc.readNewLines()
    checkEqual(initialTruncLines.count, 2, "Membaca 2 baris awal file sebelum pemotongan")

    // Tulis potongan tanpa newline ke file
    let truncHandle = try FileHandle(forWritingTo: truncFile)
    try truncHandle.seekToEnd()
    truncHandle.write(Data("potongan_lama_tersimpan".utf8))
    try truncHandle.close()
    let pendingLines = tailTrunc.readNewLines()
    checkEqual(pendingLines.count, 0, "Potongan baris tersimpan di pending")

    // Timpa file dengan isi baru yang lebih pendek (9 byte < 26 byte)
    let shorterContent = "isi_baru\n"
    try shorterContent.data(using: .utf8)?.write(to: truncFile)
    let replacedLines = tailTrunc.readNewLines()
    checkEqual(replacedLines.count, 1, "Membaca baris baru setelah file diganti dengan isi lebih pendek")
    if let replaced = replacedLines.first {
        checkEqual(String(decoding: replaced, as: UTF8.self), "isi_baru", "Pending lama dibersihkan saat file terpotong sehingga isi baru bersih")
    }

    // 4. Test JSONLTail.hasType
    let blobData = Data("{\"type\":\"api-request-blob\",\"data\":\"...\"}".utf8)
    let userData = Data("{\"type\":\"user\",\"message\":{}}".utf8)
    check(JSONLTail.hasType(blobData, in: ["api-request-blob", "file-history"]), "hasType mendeteksi api-request-blob")
    check(!JSONLTail.hasType(userData, in: ["api-request-blob", "file-history"]), "hasType mengabaikan tipe lain")
}

func testClaudeTranscript() {
    let fixturesDir = resolveFixturesDirectory()

    // 1. Sesi selesai (turnEnded -> .waiting)
    let sessionPath = fixturesDir.appendingPathComponent("claude_session.jsonl").path
    check(FileManager.default.fileExists(atPath: sessionPath), "File fixture claude_session.jsonl ada")

    let transcript = ClaudeTranscript(path: sessionPath)
    transcript.update()

    // now dihitung dari timestamp entri terakhir (10:00:10.000Z) + 5 detik
    let lastTime = ISODate.parse("2026-10-16T10:00:10.000Z")!
    let nowTurnEnded = lastTime.addingTimeInterval(5)
    let session = transcript.session(now: nowTurnEnded, modified: nowTurnEnded)

    check(session != nil, "ClaudeTranscript menghasilkan AgentSession")
    if let session {
        checkEqual(session.kind, .claudeCode, "AgentKind adalah claudeCode")
        checkEqual(session.title, "Optimasi Database Pengguna", "Title ai-title terurai benar")
        checkEqual(session.project, "/Users/dev/contoh-proyek", "CWD project terurai benar dari entri transkrip")
        checkEqual(session.costUSD, 0.045, "Total cost USD terurai benar")
        checkEqual(session.model, "claude-3-5-sonnet-20241022", "Model terurai benar")
        checkEqual(session.state, .waiting, "Status turnEnded menjadi waiting")
        checkEqual(session.detail, "Indeks idx_users_email berhasil ditambahkan ke schema.sql.", "Detail jawaban assistant terambil")
        checkEqual(session.activities.count, 4, "Aktivitas berisi tepat 4 entri (Prompt, Read, Edit, Response)")

        // Verifikasi tool Read ditutup dan durasinya dihitung akurat (10:00:04 - 10:00:02 = 2.0s)
        let readAct = session.activities.first { $0.title == "Membaca" }
        check(readAct != nil, "Tool Read tercatat sebagai aktivitas Membaca")
        checkEqual(readAct?.active, false, "Tool Read active == false setelah tool_result")
        checkEqual(readAct?.duration, 2.0, "Tool Read duration == 2.0 detik")
        checkEqual(readAct?.detail, "/Users/dev/contoh-proyek/schema.sql", "Detail file_path tool Read sesuai")

        // Verifikasi tool Edit ditutup dan durasinya dihitung akurat (10:00:07 - 10:00:05 = 2.0s)
        let editAct = session.activities.first { $0.title == "Mengedit" }
        check(editAct != nil, "Tool Edit tercatat sebagai aktivitas Mengedit")
        checkEqual(editAct?.active, false, "Tool Edit active == false setelah tool_result")
        checkEqual(editAct?.duration, 2.0, "Tool Edit duration == 2.0 detik")
        checkEqual(editAct?.detail, "/Users/dev/contoh-proyek/schema.sql", "Detail file_path tool Edit sesuai")
    }

    // 2. Transisi status pada tool yang masih terbuka (working -> menunggu izin -> idle -> nil)
    let workingPath = fixturesDir.appendingPathComponent("claude_working_session.jsonl").path
    check(FileManager.default.fileExists(atPath: workingPath), "File fixture claude_working_session.jsonl ada")

    let workingTranscript = ClaudeTranscript(path: workingPath)
    workingTranscript.update()

    let toolStartTime = ISODate.parse("2026-10-16T11:00:05.000Z")!

    // +5 detik: tool sedang berjalan normal -> .working, detail berisi nama tool & command
    let now5s = toolStartTime.addingTimeInterval(5)
    let s5s = workingTranscript.session(now: now5s, modified: now5s)
    checkEqual(s5s?.state, .working, "Tool terbuka +5s menghasilkan state .working")
    checkEqual(s5s?.detail, "Menjalankan swift run db migrate", "Tool terbuka +5s detail berisi judul tool dan command")
    checkEqual(s5s?.activities.first?.active, true, "Tool terbuka +5s aktivitas bernilai active == true")

    // +25 detik: elapsed > 20 -> .working, detail berisi "mungkin menunggu izin"
    let now25s = toolStartTime.addingTimeInterval(25)
    let s25s = workingTranscript.session(now: now25s, modified: now25s)
    checkEqual(s25s?.state, .working, "Tool terbuka +25s tetap .working")
    checkEqual(s25s?.detail, "Menjalankan (25 dtk) · mungkin menunggu izin", "Tool terbuka +25s detail menampilkan peringatan mungkin menunggu izin")

    // +700 detik: age >= 600 -> .idle, aktivitas ditandai tidak aktif
    let now700s = toolStartTime.addingTimeInterval(700)
    let s700s = workingTranscript.session(now: now700s, modified: now700s)
    checkEqual(s700s?.state, .idle, "Tool terbuka +700s (age >= 600) menghasilkan state .idle")
    checkEqual(s700s?.activities.first?.active, false, "Pada state .idle, aktivitas tool diubah menjadi active == false")

    // +31 menit (1860 detik): age >= 1800 (ClaudeCodeProvider.window) -> nil
    let now31m = toolStartTime.addingTimeInterval(31 * 60)
    let s31m = workingTranscript.session(now: now31m, modified: now31m)
    check(s31m == nil, "Sesi quiet > 30 menit menghasilkan session nil")
}

func testCodexTranscript() {
    let fixturesDir = resolveFixturesDirectory()

    // 1. Rollout selesai normal (task_complete tanpa error -> .waiting)
    let rolloutPath = fixturesDir.appendingPathComponent("codex_rollout.jsonl").path
    check(FileManager.default.fileExists(atPath: rolloutPath), "File fixture codex_rollout.jsonl ada")

    let transcript = CodexTranscript(path: rolloutPath)
    transcript.update()

    let lastTime = ISODate.parse("2026-10-16T10:30:09Z")!
    let nowCompleted = lastTime.addingTimeInterval(5)
    let session = transcript.session(now: nowCompleted, modified: nowCompleted)

    check(session != nil, "CodexTranscript menghasilkan AgentSession")
    if let session {
        checkEqual(session.kind, .codex, "AgentKind adalah codex")
        checkEqual(session.project, "/Users/dev/contoh-proyek", "CWD project terurai benar dari session_meta")
        checkEqual(session.model, "o3-mini", "Model terurai benar dari turn_context")
        checkEqual(session.tokens, 8420, "Total token terurai benar")
        checkEqual(session.state, .waiting, "Task complete tanpa error menghasilkan state waiting")
        checkEqual(session.detail, "Tugas selesai dengan sukses.", "Detail last_agent_message terurai")

        // Verifikasi function_call dengan arguments JSON (exec_command -> swift test)
        let cmdAct = session.activities.first { $0.detail == "swift test" }
        check(cmdAct != nil, "Codex function_call dengan arguments diekstrak via commandSummary")
        checkEqual(cmdAct?.title, "Menjalankan", "Title function_call Menjalankan")
        checkEqual(cmdAct?.active, false, "function_call active == false setelah function_call_output")
        checkEqual(cmdAct?.duration, 2.0, "function_call durasi == 2.0 detik (10:30:05 - 10:30:03)")

        // Verifikasi custom_tool_call dengan input teks mentah (apply_patch)
        let patchAct = session.activities.first { $0.detail.contains("Sources/App.swift") }
        check(patchAct != nil, "Codex custom_tool_call dengan input teks mentah berhasil diparse")
        checkEqual(patchAct?.title, "Menjalankan", "Title custom_tool_call Menjalankan")
        checkEqual(patchAct?.active, false, "custom_tool_call active == false setelah output")
        checkEqual(patchAct?.duration, 1.0, "custom_tool_call durasi == 1.0 detik (10:30:06 - 10:30:05)")
    }

    // 2. task_complete dengan error message -> .failed
    let failedPath = fixturesDir.appendingPathComponent("codex_failed_rollout.jsonl").path
    check(FileManager.default.fileExists(atPath: failedPath), "File fixture codex_failed_rollout.jsonl ada")

    let failedTranscript = CodexTranscript(path: failedPath)
    failedTranscript.update()

    let errorTime = ISODate.parse("2026-10-16T12:00:05Z")!
    let nowFailed = errorTime.addingTimeInterval(5)
    let sFailed = failedTranscript.session(now: nowFailed, modified: nowFailed)
    checkEqual(sFailed?.state, .failed, "Codex task_complete dengan error menghasilkan state .failed")
    checkEqual(sFailed?.detail, "Build failed with 2 errors", "Codex detail menampilkan pesan error dari task_complete")

    // 3. Tool call tanpa output -> .working dengan detail "Menjalankan <nama tool>", transisi ke .idle, dan kedaluwarsa
    let workingPath = fixturesDir.appendingPathComponent("codex_working_rollout.jsonl").path
    check(FileManager.default.fileExists(atPath: workingPath), "File fixture codex_working_rollout.jsonl ada")

    let workingTranscript = CodexTranscript(path: workingPath)
    workingTranscript.update()

    let toolTime = ISODate.parse("2026-10-16T12:30:03Z")!

    // +5 detik -> .working, detail "Menjalankan analyze_deps"
    let nowWorking = toolTime.addingTimeInterval(5)
    let sWorking = workingTranscript.session(now: nowWorking, modified: nowWorking)
    checkEqual(sWorking?.state, .working, "Codex tool call terbuka +5s menghasilkan state .working")
    checkEqual(sWorking?.detail, "Menjalankan analyze_deps", "Codex detail menampilkan 'Menjalankan <nama tool>'")

    // +700 detik -> .idle
    let nowIdle = toolTime.addingTimeInterval(700)
    let sIdle = workingTranscript.session(now: nowIdle, modified: nowIdle)
    checkEqual(sIdle?.state, .idle, "Codex tool call terbuka +700s (age >= 600) menghasilkan state .idle")

    // +31 menit -> nil
    let nowExpired = toolTime.addingTimeInterval(31 * 60)
    let sExpired = workingTranscript.session(now: nowExpired, modified: nowExpired)
    check(sExpired == nil, "Codex quiet > 30 menit menghasilkan session nil")
}

func testStreamReader() {
    let fixturePath = resolveFixturesDirectory().appendingPathComponent("agy_stream.jsonl").path
    check(FileManager.default.fileExists(atPath: fixturePath), "File fixture agy_stream.jsonl ada")

    let reader = StreamReader()
    reader.reset(path: fixturePath)
    let changed = reader.poll()

    check(changed, "StreamReader.poll() mengembalikan true saat ada log baru")
    checkEqual(reader.conversationId, "conv-synthetic-999", "Conversation ID terurai")
    checkEqual(reader.model, "gemini-2.5-pro", "Model terurai")
    checkEqual(reader.totalTokens, 350, "Total token terakumulasi")

    if let outcome = reader.outcome {
        checkEqual(outcome.status, "SUCCESS", "Outcome status SUCCESS")
        check(outcome.error == nil, "Outcome error nil")
    } else {
        check(false, "Outcome tidak boleh nil setelah run selesai")
    }

    let activities = reader.visibleActivities()
    checkEqual(activities.count, 2, "Visible activities berisi 2 aktivitas")
    let toolAct = activities.first { $0.kind == .read }
    check(toolAct != nil, "Aktivitas tool view_file dipetakan ke .read (Membaca)")
    checkEqual(toolAct?.detail, "/Users/dev/contoh-proyek/Sources/Main.swift", "Parameter detail tool terisi")

    // Test permission denied fixture dengan format jetski asli
    let deniedFixturePath = resolveFixturesDirectory().appendingPathComponent("agy_stream_denied.jsonl").path
    check(FileManager.default.fileExists(atPath: deniedFixturePath), "File fixture agy_stream_denied.jsonl ada")

    let readerDenied = StreamReader()
    readerDenied.reset(path: deniedFixturePath)
    _ = readerDenied.poll()

    if let outcomeDenied = readerDenied.outcome {
        checkEqual(outcomeDenied.status, "DENIED", "auto-denied mengubah status outcome menjadi DENIED")
        check(outcomeDenied.error?.contains("tidak diizinkan") == true, "Pesan error izin denied sesuai")
    } else {
        check(false, "Outcome denied harus terisi")
    }
}

func testAegisLoopAndReview() throws {
    let fixturesDir = resolveFixturesDirectory()

    // Test reviewCounts from REVIEW.md fixture
    let counts = AegisLoop.reviewCounts(in: fixturesDir.path)
    checkEqual(counts.open, 1, "ReviewCounts terbuka dihitung 1")
    checkEqual(counts.fixed, 1, "ReviewCounts diperbaiki dihitung 1")
    checkEqual(counts.rejected, 1, "ReviewCounts ditolak dihitung 1")

    // Test decoding aegis_state.json
    let stateFile = fixturesDir.appendingPathComponent("aegis_state.json")
    let data = try Data(contentsOf: stateFile)
    let state = try JSONDecoder().decode(LoopState.self, from: data)

    checkEqual(state.project, "/Users/dev/contoh-proyek", "LoopState project")
    checkEqual(state.phase, "0", "LoopState phase")
    checkEqual(state.round, 1, "LoopState round")
    checkEqual(state.status, "gemini", "LoopState status")

    let snapshot = LoopSnapshot(state: state, review: counts)
    checkEqual(snapshot.status, .gemini, "LoopSnapshot status enum gemini")
    checkEqual(snapshot.subtitle, "Tahap 0 · Putaran 1 — Tahap 0 persiapan test", "Subtitle LoopSnapshot diformat rapi")
}

// MARK: - Main Execution

print("========================================")
print("🚀 Menjalankan AgentMonitorChecks")
print("========================================")

let startTime = Date()

runSuite("Format & ISODate", testFormatAndDates)
runSuite("JSONLTail Incremental Reader", testJSONLTail)
runSuite("ClaudeTranscript Parser", testClaudeTranscript)
runSuite("CodexTranscript Parser", testCodexTranscript)
runSuite("StreamReader Parser", testStreamReader)
runSuite("AegisLoop & REVIEW.md Parser", testAegisLoopAndReview)

let duration = String(format: "%.3f", Date().timeIntervalSince(startTime))

print("========================================")
if failedAssertions == 0 {
    print("✅ SEMUA PENGUJIAN LOLOS! (\(totalAssertions) pemeriksaan dalam \(duration) dtk)")
    print("========================================")
    exit(0)
} else {
    print("❌ DITEMUKAN \(failedAssertions) KEGAGALAN dari \(totalAssertions) pemeriksaan!")
    print("========================================")
    exit(1)
}
