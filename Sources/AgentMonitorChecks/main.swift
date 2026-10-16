import Foundation
import UserNotifications
import AgentMonitorKit

setvbuf(stdout, nil, _IOLBF, 0)

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

@MainActor
private func runSuiteAsync(_ name: String, _ body: () async throws -> Void) async {
    let startFailures = failedAssertions
    print("▶ Menguji \(name)...")
    do {
        try await body()
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

func testTranscriptActivityLog() {
    // 1. Batas 80: aktivitas tertua dibuang dan id tetap berurutan
    let log80 = TranscriptActivityLog()
    for i in 1...85 {
        let id = log80.append(.command, "Aktivitas \(i)", "detail \(i)")
        checkEqual(id, i, "ID aktivitas bertambah berurutan dari 1 hingga 85")
    }
    checkEqual(log80.activities.count, 80, "TranscriptActivityLog membatasi riwayat maksimal 80 aktivitas")
    checkEqual(log80.activities.first?.id, 6, "Aktivitas tertua dibuang (id 1-5 dibuang, dimulai dari 6)")
    checkEqual(log80.activities.last?.id, 85, "Aktivitas terbaru adalah id 85")

    // 2. Detail dipangkas 300 karakter
    let longDetail = String(repeating: "x", count: 350)
    let logSnippet = TranscriptActivityLog()
    logSnippet.append(.prompt, "Prompt", longDetail)
    if let act = logSnippet.activities.first {
        checkEqual(act.detail.count, 301, "Detail dipangkas menjadi 300 karakter ditambah elipsis (total 301 karakter)")
        check(act.detail.hasSuffix("…"), "Detail yang dipangkas diakhiri karakter elipsis")
        checkEqual(act.detail, String(repeating: "x", count: 300) + "…", "Isi detail tepat 300 karakter awal diikuti elipsis")
    }

    // 3. Menutup id yang tidak dikenal tidak mengubah apa pun
    let logUnknown = TranscriptActivityLog()
    let knownTime = Date(timeIntervalSince1970: 1000)
    logUnknown.append(.command, "Tool", "arg", active: true, at: knownTime, toolId: "call_known")
    checkEqual(logUnknown.openTools.count, 1, "openTools mencatat 1 tool terbuka")
    logUnknown.closeTool("call_unknown", at: knownTime.addingTimeInterval(5))
    checkEqual(logUnknown.openTools.count, 1, "Menutup id tidak dikenal tidak mengubah openTools")
    checkEqual(logUnknown.activities.first?.active, true, "Menutup id tidak dikenal tidak mengubah status active")
    checkEqual(logUnknown.activities.first?.duration, nil, "Menutup id tidak dikenal tidak mengubah duration")

    // 4. Menutup id yang sama dua kali hanya berlaku sekali, dan durasinya tidak berubah
    let logDuplicate = TranscriptActivityLog()
    let startTime = Date(timeIntervalSince1970: 2000)
    logDuplicate.append(.command, "Tool", "arg", active: true, at: startTime, toolId: "call_duplicate")
    let closeTime1 = startTime.addingTimeInterval(2.5)
    logDuplicate.closeTool("call_duplicate", at: closeTime1)
    checkEqual(logDuplicate.activities.first?.active, false, "Penutupan pertama mengubah active menjadi false")
    checkEqual(logDuplicate.activities.first?.duration, 2.5, "Penutupan pertama menghitung durasi 2.5 detik")
    checkEqual(logDuplicate.openTools.count, 0, "Penutupan pertama menghapus id dari openTools")

    let closeTime2 = startTime.addingTimeInterval(10.0)
    logDuplicate.closeTool("call_duplicate", at: closeTime2)
    checkEqual(logDuplicate.activities.first?.active, false, "Penutupan kedua mempertahankan active == false")
    checkEqual(logDuplicate.activities.first?.duration, 2.5, "Penutupan kedua tidak mengubah durasi yang telah dihitung sebelumnya")

    // 5. Daftar tampil: 30 terbaru, terbalik, dan active dipaksa false kalau tidak .working
    let logDisplay = TranscriptActivityLog()
    for i in 1...40 {
        logDisplay.append(.command, "Tool \(i)", "detail \(i)", active: true)
    }

    // Saat state .working: 30 terbaru, terbalik, active tetap true
    let workingVisible = logDisplay.visibleActivities(for: .working)
    checkEqual(workingVisible.count, 30, "Daftar tampil berisi tepat 30 aktivitas terbaru")
    checkEqual(workingVisible.first?.title, "Tool 40", "Aktivitas pertama pada daftar tampil adalah yang terbaru (Tool 40)")
    checkEqual(workingVisible.last?.title, "Tool 11", "Aktivitas terakhir pada daftar tampil adalah Tool 11")
    checkEqual(workingVisible.first?.active, true, "Saat .working, aktivitas aktif mempertahankan active == true")

    // Saat state bukan .working (misal .waiting atau .idle): 30 terbaru, terbalik, active dipaksa false
    let waitingVisible = logDisplay.visibleActivities(for: .waiting)
    checkEqual(waitingVisible.count, 30, "Daftar tampil saat bukan .working tetap berisi 30 aktivitas")
    checkEqual(waitingVisible.first?.title, "Tool 40", "Urutan tetap terbalik (Tool 40 di awal)")
    checkEqual(waitingVisible.first?.active, false, "Saat bukan .working, aktivitas aktif dipaksa active == false")
    check(waitingVisible.allSatisfy { !$0.active }, "Seluruh aktivitas pada daftar tampil bukan .working memiliki active == false")
    checkEqual(logDisplay.activities.last?.active, true, "Log internal tetap mempertahankan status active asli")
}

func testPresenceProvider() {
    let provider = PresenceProvider()
    let processes = [
        ProcessEntry(pid: 101, elapsed: "01:23", cpu: 12.5, memoryMB: 150, path: "/Applications/Claude.app/Contents/MacOS/Claude"),
        ProcessEntry(pid: 102, elapsed: "01:20", cpu: 2.5, memoryMB: 50, path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"),
        ProcessEntry(pid: 201, elapsed: "10:00", cpu: 0.1, memoryMB: 20, path: "/usr/bin/login")
    ]
    let context = PollContext(now: Date(), processes: processes)
    let sessions = provider.poll(context)

    checkEqual(sessions.count, 1, "PresenceProvider mendeteksi tepat 1 sesi untuk Claude desktop")
    if let session = sessions.first {
        checkEqual(session.id, "app:claudeDesktop", "ID sesi sesuai signature claudeDesktop")
        checkEqual(session.kind, .claudeDesktop, "AgentKind adalah .claudeDesktop")
        checkEqual(session.state, .running, "Status sesi adalah .running")
        checkEqual(session.title, "Aplikasi desktop", "Judul sesi adalah 'Aplikasi desktop'")
        checkEqual(session.detail, "Berjalan", "Detail sesi adalah 'Berjalan'")
        checkEqual(session.cpu, 15.0, "CPU kedua proses dijumlahkan (12.5 + 2.5 = 15.0)")
        checkEqual(session.memoryMB, 200, "Memori kedua proses dijumlahkan (150 + 50 = 200)")
    }
}

func testOllamaParsing() {
    // Ada model: daftar nama digabung dengan koma
    let jsonWithModels = """
    {"models": [{"name": "qwen2.5-coder:7b"}, {"name": "llama3.2:3b"}]}
    """.data(using: .utf8)!
    let resultWithModels = PresenceProvider.parseOllamaModels(jsonWithModels)
    checkEqual(resultWithModels, "Model aktif: qwen2.5-coder:7b, llama3.2:3b", "Parsing ada model menghasilkan 'Model aktif: a, b'")

    // Daftar kosong: string keterangan kosong
    let jsonEmpty = """
    {"models": []}
    """.data(using: .utf8)!
    let resultEmpty = PresenceProvider.parseOllamaModels(jsonEmpty)
    checkEqual(resultEmpty, "Tidak ada model dimuat", "Daftar model kosong menghasilkan 'Tidak ada model dimuat'")

    // JSON rusak atau tidak sesuai schema: nil
    let corruptJSON = "bukan json valid".data(using: .utf8)!
    checkEqual(PresenceProvider.parseOllamaModels(corruptJSON), nil, "JSON rusak menghasilkan nil")

    let missingModelsField = "{\"status\": \"ok\"}".data(using: .utf8)!
    checkEqual(PresenceProvider.parseOllamaModels(missingModelsField), nil, "JSON tanpa properti models menghasilkan nil")
}

private final class MockProvider: AgentProvider, @unchecked Sendable {
    let sessionsToReturn: [AgentSession]
    var receivedContext: PollContext?

    init(sessions: [AgentSession] = []) {
        self.sessionsToReturn = sessions
    }

    func poll(_ context: PollContext) -> [AgentSession] {
        self.receivedContext = context
        return sessionsToReturn
    }
}

@MainActor
func testPollingEngine() async {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let s1 = AgentSession(
        id: "s1", kind: .claudeCode, title: "Sesi 1",
        state: .working, detail: "Working 10s ago",
        lastActivity: now.addingTimeInterval(-10)
    )
    let s2 = AgentSession(
        id: "s2", kind: .claudeCode, title: "Sesi 2",
        state: .waiting, detail: "Waiting 20s ago",
        lastActivity: now.addingTimeInterval(-20)
    )
    let s3 = AgentSession(
        id: "s3", kind: .geminiCLI, title: "Sesi 3",
        state: .working, detail: "Working 5s ago",
        lastActivity: now.addingTimeInterval(-5)
    )
    let s4 = AgentSession(
        id: "s4", kind: .codex, title: "Sesi 4",
        state: .idle, detail: "Idle now",
        lastActivity: now
    )

    let mock1 = MockProvider(sessions: [s1, s2])
    let mock2 = MockProvider(sessions: [s3, s4])

    let syntheticProcesses = [
        ProcessEntry(pid: 999, elapsed: "00:05", cpu: 1.0, memoryMB: 50, path: "/usr/local/bin/dummy")
    ]

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let loopJSON = """
    {"project": "/Users/dev/contoh-proyek", "round": 1, "status": "gemini", "note": "Testing"}
    """.data(using: .utf8)!
    try? loopJSON.write(to: tempDir.appendingPathComponent("state.json"))

    let aegis = AegisLoop(directory: tempDir)

    let engine = PollingEngine(
        providers: [mock1, mock2],
        processSource: { syntheticProcesses },
        aegis: aegis
    )

    let result = await engine.poll(now: now)

    // Sesi digabung dari semua provider dan diurutkan:
    // .waiting sebelum .working; untuk state yang sama, lastActivity terbaru lebih dulu; lalu .idle
    checkEqual(result.sessions.count, 4, "Sesi digabung dari semua provider (total 4)")
    checkEqual(result.sessions[0].id, "s2", "Sesi 1 adalah .waiting (s2)")
    checkEqual(result.sessions[1].id, "s3", "Sesi 2 adalah .working terbaru (s3, -5s)")
    checkEqual(result.sessions[2].id, "s1", "Sesi 3 adalah .working lebih lama (s1, -10s)")
    checkEqual(result.sessions[3].id, "s4", "Sesi 4 adalah .idle (s4)")

    // Setiap provider menerima now, processes, dan loop yang sama
    check(mock1.receivedContext != nil, "Provider 1 menerima context")
    check(mock2.receivedContext != nil, "Provider 2 menerima context")

    if let c1 = mock1.receivedContext, let c2 = mock2.receivedContext {
        checkEqual(c1.now, now, "Provider 1 menerima now yang tepat")
        checkEqual(c2.now, now, "Provider 2 menerima now yang sama")

        checkEqual(c1.processes.count, 1, "Provider 1 menerima daftar processes")
        checkEqual(c1.processes.first?.pid, 999, "Provider 1 menerima process dengan PID 999")
        checkEqual(c2.processes.count, 1, "Provider 2 menerima daftar processes yang sama")
        checkEqual(c2.processes.first?.pid, 999, "Provider 2 menerima process dengan PID 999")

        checkEqual(c1.loop?.project, "/Users/dev/contoh-proyek", "Provider 1 menerima loop state project")
        checkEqual(c2.loop?.project, "/Users/dev/contoh-proyek", "Provider 2 menerima loop state project yang sama")
        checkEqual(c1.loop?.status, "gemini", "Provider 1 menerima loop status 'gemini'")
        checkEqual(c2.loop?.status, "gemini", "Provider 2 menerima loop status 'gemini'")
    }

    // Uji penggunaan ulang snapshot proses:
    final class ProcessCounter: @unchecked Sendable {
        var count = 0
        func next() -> [ProcessEntry] {
            count += 1
            return [ProcessEntry(pid: 100, elapsed: "01:00", cpu: 5.0, memoryMB: 100, path: "/test")]
        }
    }

    let counter = ProcessCounter()
    let engineWithCounter = PollingEngine(
        providers: [],
        processSource: { counter.next() }
    )

    let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

    // 1. Poll pertama dari event file: memanggil processSource
    _ = await engineWithCounter.poll(now: baseTime, fromFileEvent: true)
    checkEqual(counter.count, 1, "Poll pertama dari event file memanggil processSource")

    // 2. Poll kedua dari event file dalam waktu 5 detik (2 detik kemudian): processSource tidak dipanggil lagi
    _ = await engineWithCounter.poll(now: baseTime.addingTimeInterval(2), fromFileEvent: true)
    checkEqual(counter.count, 1, "Dua poll event file dalam 5 detik hanya memanggil processSource sekali")

    // 3. Poll biasa (timer, fromFileEvent: false) 3 detik kemudian: selalu memanggil processSource
    _ = await engineWithCounter.poll(now: baseTime.addingTimeInterval(3), fromFileEvent: false)
    checkEqual(counter.count, 2, "Poll biasa (timer) selalu memanggil processSource")

    // 4. Poll dari event file setelah snapshot berumur >= 5 detik (8.5 detik dari awal, yaitu 5.5 detik setelah poll #3): memanggil processSource lagi
    _ = await engineWithCounter.poll(now: baseTime.addingTimeInterval(8.5), fromFileEvent: true)
    checkEqual(counter.count, 3, "Poll event file setelah snapshot berumur >= 5 detik memanggil processSource lagi")
}

private final class EventWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var triggered = false
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeoutWorkItem: DispatchWorkItem?

    func trigger() {
        lock.lock()
        defer { lock.unlock() }
        triggered = true
        if let cont = continuation {
            continuation = nil
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            cont.resume(returning: true)
        }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        triggered = false
    }

    func waitForEvent(timeoutSeconds: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            lock.lock()
            if triggered {
                triggered = false
                lock.unlock()
                cont.resume(returning: true)
                return
            }

            self.continuation = cont
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                if let waiting = self.continuation {
                    self.continuation = nil
                    self.timeoutWorkItem = nil
                    waiting.resume(returning: false)
                }
            }
            self.timeoutWorkItem = workItem
            lock.unlock()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: workItem)
        }
    }
}

@MainActor
func testFileWatcher() async {
    let tempWatched = FileManager.default.temporaryDirectory.appendingPathComponent("watch-test-\(UUID().uuidString)")
    let tempOther = FileManager.default.temporaryDirectory.appendingPathComponent("other-test-\(UUID().uuidString)")

    try? FileManager.default.createDirectory(at: tempWatched, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: tempOther, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: tempWatched)
        try? FileManager.default.removeItem(at: tempOther)
    }

    let waiter = EventWaiter()
    let watcher = FileWatcher(paths: [tempWatched.path], latency: 0.1) {
        waiter.trigger()
    }

    // 1. Menulis file di folder yang dipantau memicu callback dalam waktu <= 3 detik
    let testFile = tempWatched.appendingPathComponent("file1.txt")
    try? "perubahan 1".data(using: .utf8)?.write(to: testFile)

    let triggeredWatched = await waiter.waitForEvent(timeoutSeconds: 3.0)
    check(triggeredWatched, "Menulis file di folder yang dipantau memicu callback dalam waktu <= 3 detik")

    // 2. Menulis file di folder lain yang tidak dipantau tidak memicu callback dalam 2 detik
    waiter.reset()
    let otherFile = tempOther.appendingPathComponent("file2.txt")
    try? "perubahan folder lain".data(using: .utf8)?.write(to: otherFile)

    let triggeredOther = await waiter.waitForEvent(timeoutSeconds: 2.0)
    check(!triggeredOther, "Menulis file di folder lain yang tidak dipantau tidak memicu callback dalam 2 detik")

    // 3. Setelah watcher dihentikan, menulis file tidak lagi memicu callback
    watcher.stop()
    waiter.reset()

    let stoppedFile = tempWatched.appendingPathComponent("file3.txt")
    try? "perubahan setelah stop".data(using: .utf8)?.write(to: stoppedFile)

    let triggeredAfterStop = await waiter.waitForEvent(timeoutSeconds: 2.0)
    check(!triggeredAfterStop, "Setelah watcher dihentikan, menulis file tidak lagi memicu callback")
}

// MARK: - Tahap 2a Test Suites

func testHookHandler() {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent_monitor_hook_handler_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let receivedTime = ISODate.parse("2026-10-16T12:00:00.000Z")!

    // 1. Payload PermissionRequest -> satu baris JSON dengan field yang benar, termasuk tool_summary dan tanpa tool_input
    let permPayload = """
    {
      "hook_event_name": "PermissionRequest",
      "session_id": "session-abc-1",
      "cwd": "/Users/dev/contoh-proyek",
      "tool_name": "Bash",
      "tool_input": {
        "command": "npm test",
        "description": "Run tests"
      }
    }
    """.data(using: .utf8)!

    let processed1 = HookHandler.processInput(permPayload, receivedAt: receivedTime, directory: tempDir)
    check(processed1, "processInput sukses memproses payload PermissionRequest")

    let eventsFile = tempDir.appendingPathComponent("events.jsonl")
    let lines1 = (try? String(contentsOf: eventsFile, encoding: .utf8))?
        .split(separator: "\n", omittingEmptySubsequences: true) ?? []
    checkEqual(lines1.count, 1, "Tepat satu baris ditulis ke events.jsonl")

    if let firstLine = lines1.first,
       let json1 = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any] {
        checkEqual(json1["event"] as? String, "PermissionRequest", "Event PermissionRequest tercatat")
        checkEqual(json1["session_id"] as? String, "session-abc-1", "session_id PermissionRequest tercatat")
        checkEqual(json1["cwd"] as? String, "/Users/dev/contoh-proyek", "cwd PermissionRequest tercatat")
        checkEqual(json1["tool_name"] as? String, "Bash", "tool_name tercatat")
        checkEqual(json1["tool_summary"] as? String, "npm test", "tool_summary diparsing dari tool_input")
        check(json1["tool_input"] == nil, "tool_input utuh tidak disimpan")
        checkEqual(json1["received_at"] as? String, ISODate.stringFractional(receivedTime), "received_at terformat ISODate.stringFractional dengan pecahan detik")
    }

    // Pemangkasan tool_summary hingga 160 karakter
    let longCommand = String(repeating: "echo 'panjang sekali'; ", count: 20)
    let longPayload = """
    {
      "hook_event_name": "PermissionRequest",
      "session_id": "session-long",
      "cwd": "/Users/dev/contoh-proyek",
      "tool_name": "Bash",
      "tool_input": {
        "command": "\(longCommand)"
      }
    }
    """.data(using: .utf8)!
    HookHandler.processInput(longPayload, receivedAt: receivedTime, directory: tempDir)
    let linesLong = (try? String(contentsOf: eventsFile, encoding: .utf8))?
        .split(separator: "\n", omittingEmptySubsequences: true) ?? []
    if let lastLine = linesLong.last,
       let jsonLong = try? JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any] {
        let summary = jsonLong["tool_summary"] as? String ?? ""
        check(summary.count <= 160, "tool_summary dipangkas maksimal 160 karakter (aktual: \(summary.count))")
    }

    // 2. Payload Notification permission_prompt
    let notifPayload = """
    {
      "hook_event_name": "Notification",
      "session_id": "session-abc-2",
      "cwd": "/Users/dev/contoh-proyek",
      "notification_type": "permission_prompt",
      "message": "Claude butuh izin Anda"
    }
    """.data(using: .utf8)!

    let processed2 = HookHandler.processInput(notifPayload, receivedAt: receivedTime, directory: tempDir)
    check(processed2, "processInput sukses memproses payload Notification")

    let lines2 = (try? String(contentsOf: eventsFile, encoding: .utf8))?
        .split(separator: "\n", omittingEmptySubsequences: true) ?? []
    if let lastLine = lines2.last,
       let json2 = try? JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any] {
        checkEqual(json2["event"] as? String, "Notification", "Event Notification tercatat")
        checkEqual(json2["notification_type"] as? String, "permission_prompt", "notification_type tercatat")
        checkEqual(json2["message"] as? String, "Claude butuh izin Anda", "message tercatat")
        check(json2["tool_name"] == nil, "tool_name tidak ada pada Notification")
        check(json2["tool_summary"] == nil, "tool_summary tidak ada pada Notification")
    }

    // 3. Stdin bukan JSON -> tidak menulis apa pun
    let tempDirInvalid = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent_monitor_hook_invalid_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDirInvalid) }

    let invalidResult1 = HookHandler.processInput("bukan json".data(using: .utf8)!, directory: tempDirInvalid)
    check(!invalidResult1, "processInput menolak string non-JSON")
    check(!FileManager.default.fileExists(atPath: tempDirInvalid.appendingPathComponent("events.jsonl").path), "File events.jsonl tidak dibuat untuk data non-JSON")

    let invalidResult2 = HookHandler.processInput(Data(), directory: tempDirInvalid)
    check(!invalidResult2, "processInput menolak data kosong")

    // 4. Rotasi saat file lebih dari 1 MB
    let tempDirRotate = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent_monitor_hook_rotate_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDirRotate) }
    try? FileManager.default.createDirectory(at: tempDirRotate, withIntermediateDirectories: true)

    let rotateFile = tempDirRotate.appendingPathComponent("events.jsonl")
    let oldRotatedFile = tempDirRotate.appendingPathComponent("events.jsonl.1")

    // Tulis file lama yang melebihi 1 MB
    let largeContent = Data(repeating: 0x42, count: 1_000_050)
    try? largeContent.write(to: rotateFile)
    try? "old backup to be overwritten".data(using: .utf8)?.write(to: oldRotatedFile)

    let rotatedProcessed = HookHandler.processInput(permPayload, receivedAt: receivedTime, directory: tempDirRotate, maxFileSize: 1_000_000)
    check(rotatedProcessed, "processInput berhasil memicu rotasi")

    check(FileManager.default.fileExists(atPath: oldRotatedFile.path), "events.jsonl.1 berhasil dibuat saat rotasi")
    let rotatedSize = (try? FileManager.default.attributesOfItem(atPath: oldRotatedFile.path))?[.size] as? Int64 ?? 0
    checkEqual(rotatedSize, 1_000_050, "events.jsonl.1 berisi data lama 1 MB dan menimpa backup sebelumnya")

    let newFileSize = (try? FileManager.default.attributesOfItem(atPath: rotateFile.path))?[.size] as? Int64 ?? 0
    check(newFileSize > 0 && newFileSize < 1000, "events.jsonl baru hanya berisi baris baru setelah rotasi")
}

func testHookInstaller() {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent_monitor_hook_installer_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let settingsURL = tempDir.appendingPathComponent("settings.json")
    let backupURL = URL(fileURLWithPath: settingsURL.path + ".agent-monitor.bak")
    let appPath = "/Applications/Agent Monitor.app/Contents/MacOS/Agent Monitor"

    // 1. Path dikutip benar dengan tanda kutip tunggal dan escaping (termasuk spasi, ', $)
    let cmd = HookInstaller.command(for: appPath)
    checkEqual(cmd, "[ -x '\(appPath)' ] && '\(appPath)' --agent-monitor-hook || true", "Command dikutip benar dengan tanda kutip tunggal")

    let trickyPath = "/Applications/Toni's $Special App.app/Contents/MacOS/Agent Monitor"
    let trickyCmd = HookInstaller.command(for: trickyPath)
    let expectedEscaped = "/Applications/Toni'\\''s $Special App.app/Contents/MacOS/Agent Monitor"
    checkEqual(trickyCmd, "[ -x '\(expectedEscaped)' ] && '\(expectedEscaped)' --agent-monitor-hook || true", "Command meng-escape tanda kutip tunggal dan mempertahankan $ secara literal")

    // 2. Settings kosong (file belum ada)
    checkEqual(HookInstaller.status(settingsURL: settingsURL), .notInstalled, "Status awal belum terpasang")
    try? HookInstaller.install(settingsURL: settingsURL, executablePath: appPath)
    checkEqual(HookInstaller.status(settingsURL: settingsURL), .installed, "Status setelah install menjadi terpasang")
    check(!FileManager.default.fileExists(atPath: backupURL.path), "Backup tidak dibuat jika file sebelumnya belum ada")

    // 3. Backup dibuat saat file sudah ada
    try? HookInstaller.install(settingsURL: settingsURL, executablePath: appPath)
    check(FileManager.default.fileExists(atPath: backupURL.path), "Backup settings.json.agent-monitor.bak dibuat saat menimpa file yang ada")

    // 4. Install dua kali -> tidak duplikat (idempotensi)
    if let data = try? Data(contentsOf: settingsURL),
       let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let hooks = json["hooks"] as? [String: Any] {
        let permMatchers = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        checkEqual(permMatchers.count, 1, "PermissionRequest hanya memiliki 1 grup matcher")
        let permHooks = permMatchers.first?["hooks"] as? [[String: Any]] ?? []
        checkEqual(permHooks.count, 1, "PermissionRequest tidak menduplikasi hook entry")

        let notifMatchers = hooks["Notification"] as? [[String: Any]] ?? []
        checkEqual(notifMatchers.count, 1, "Notification hanya memiliki 1 grup matcher")
        let notifHooks = notifMatchers.first?["hooks"] as? [[String: Any]] ?? []
        checkEqual(notifHooks.count, 1, "Notification tidak menduplikasi hook entry")
    }

    // 5. Entri lama dengan path berbeda -> diganti
    let newAppPath = "/Volumes/Custom/Agent Monitor.app/Contents/MacOS/Agent Monitor"
    try? HookInstaller.install(settingsURL: settingsURL, executablePath: newAppPath)
    if let data = try? Data(contentsOf: settingsURL),
       let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let hooks = json["hooks"] as? [String: Any],
       let permMatchers = hooks["PermissionRequest"] as? [[String: Any]],
       let firstPerm = (permMatchers.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String {
        check(firstPerm.contains(newAppPath), "Path hook lama diperbarui ke path baru")
        check(!firstPerm.contains(appPath), "Path lama tidak tersisa")
    }

    // 6. Settings yang sudah punya hook dan key lain milik user -> tetap utuh
    let userSettings: [String: Any] = [
        "theme": "dark",
        "customKey": 42,
        "hooks": [
            "PreToolUse": [
                [
                    "matcher": "Bash",
                    "hooks": [["type": "command", "command": "custom_pre_tool.sh"]]
                ]
            ],
            "PermissionRequest": [
                [
                    "matcher": "",
                    "hooks": [["type": "command", "command": "user_watcher.sh"]]
                ]
            ]
        ]
    ]

    let merged = HookInstaller.install(in: userSettings, executablePath: appPath)
    checkEqual(merged["theme"] as? String, "dark", "Key root theme milik user tetap utuh")
    checkEqual(merged["customKey"] as? Int, 42, "Key root customKey milik user tetap utuh")
    let mergedHooks = merged["hooks"] as? [String: Any] ?? [:]
    check(mergedHooks["PreToolUse"] != nil, "Event hook PreToolUse milik user tetap utuh")

    let mergedPerm = mergedHooks["PermissionRequest"] as? [[String: Any]] ?? []
    let mergedPermHooks = mergedPerm.first?["hooks"] as? [[String: Any]] ?? []
    checkEqual(mergedPermHooks.count, 2, "Matcher '' menggabungkan hook user dan hook kita")
    check(mergedPermHooks.contains { ($0["command"] as? String) == "user_watcher.sh" }, "Hook user_watcher.sh tetap ada")

    // 7. Uninstall hanya menghapus milik kita dan membersihkan container kosong
    let uninstalled = HookInstaller.uninstall(from: merged)
    checkEqual(uninstalled["theme"] as? String, "dark", "Root theme tetap utuh setelah uninstall")
    let uninstalledHooks = uninstalled["hooks"] as? [String: Any] ?? [:]
    check(uninstalledHooks["PreToolUse"] != nil, "PreToolUse user tetap ada setelah uninstall")
    let uninstalledPerm = uninstalledHooks["PermissionRequest"] as? [[String: Any]] ?? []
    let uninstalledPermHooks = uninstalledPerm.first?["hooks"] as? [[String: Any]] ?? []
    checkEqual(uninstalledPermHooks.count, 1, "Hook kita dihapus dari matcher")
    checkEqual(uninstalledPermHooks.first?["command"] as? String, "user_watcher.sh", "Hanya hook user yang tersisa")
    check(uninstalledHooks["Notification"] == nil, "Notification yang kosong dibersihkan dari hooks")

    // Uninstall saat hanya ada hook kita -> key 'hooks' terhapus sepenuhnya
    let onlyOurHooksSettings = HookInstaller.install(in: [:], executablePath: appPath)
    let cleaned = HookInstaller.uninstall(from: onlyOurHooksSettings)
    check(cleaned["hooks"] == nil, "Key hooks yang menjadi kosong dihapus sepenuhnya")

    // 8. File yang tidak bisa di-parse -> error, file tidak berubah
    let corruptURL = tempDir.appendingPathComponent("corrupt_settings.json")
    let corruptContent = "{ json rusak tanpa penutup"
    try? corruptContent.write(to: corruptURL, atomically: true, encoding: .utf8)
    var threwExpectedError = false
    do {
        try HookInstaller.install(settingsURL: corruptURL, executablePath: appPath)
    } catch let error as HookInstaller.InstallError {
        threwExpectedError = (error == .unparseableSettings)
    } catch {}
    check(threwExpectedError, "File rusak menghasilkan error unparseableSettings")
    let afterCorruptContent = (try? String(contentsOf: corruptURL, encoding: .utf8)) ?? ""
    checkEqual(afterCorruptContent, corruptContent, "Isi file rusak tidak berubah sama sekali")

    // 9. disableAllHooks: true
    let disabledSettings: [String: Any] = [
        "disableAllHooks": true,
        "hooks": onlyOurHooksSettings["hooks"] as Any
    ]
    checkEqual(HookInstaller.status(in: disabledSettings), .disabled, "status menghasilkan .disabled saat disableAllHooks == true")

    // 10. Penolakan jika aplikasi tidak berjalan dari bundle .app
    var threwBundleError = false
    do {
        // Bundle.main di lingkungan CLI test bukan .app
        try HookInstaller.install(settingsURL: settingsURL, executablePath: nil, bundle: Bundle.main)
    } catch let error as HookInstaller.InstallError {
        threwBundleError = (error == .notInAppBundle)
    } catch {}
    check(threwBundleError, "Install menolak eksekusi di luar bundle .app")

    // 11. Container kosong yang bukan karena hook kita tidak ikut dihapus (#20)
    let preExistingEmpty: [String: Any] = [
        "hooks": [
            "PreToolUse": [] as [Any],
            "PostToolUse": [
                [
                    "matcher": "Bash",
                    "hooks": [] as [Any]
                ]
            ],
            "Notification": [
                [
                    "matcher": "idle",
                    "hooks": [] as [Any]
                ],
                [
                    "matcher": "permission_prompt",
                    "hooks": [["type": "command", "command": HookInstaller.command(for: appPath)]]
                ]
            ]
        ]
    ]
    let uninstalledPreserved = HookInstaller.uninstall(from: preExistingEmpty)
    let preservedHooks = uninstalledPreserved["hooks"] as? [String: Any] ?? [:]
    check(preservedHooks["PreToolUse"] != nil, "Event PreToolUse yang memang kosong sejak awal tidak dihapus")
    check(preservedHooks["PostToolUse"] != nil, "Event PostToolUse dengan matcher ber-hooks kosong tetap ada")
    let preservedNotifs = preservedHooks["Notification"] as? [[String: Any]] ?? []
    checkEqual(preservedNotifs.count, 1, "Hanya matcher yang berisi hook kita yang dihapus saat kosong")
    checkEqual(preservedNotifs.first?["matcher"] as? String, "idle", "Matcher idle milik user tetap utuh")

    // 12. withoutEscapingSlashes (#18)
    let slashTestURL = tempDir.appendingPathComponent("slash_test.json")
    try? HookInstaller.install(settingsURL: slashTestURL, executablePath: appPath)
    let slashContent = (try? String(contentsOf: slashTestURL, encoding: .utf8)) ?? ""
    check(!slashContent.contains("\\/"), "settings.json yang ditulis tidak mengandung escaped slash (\\/)")
    check(slashContent.contains("/Applications/Agent Monitor.app"), "Path di settings.json tetap menggunakan slash biasa")

    // 13. Skip write & backup saat uninstall jika tidak ada perubahan (#18)
    let noChangeURL = tempDir.appendingPathComponent("no_change_settings.json")
    let noChangeBakURL = URL(fileURLWithPath: noChangeURL.path + ".agent-monitor.bak")
    let originalNoChange = "{\n  \"theme\" : \"light\"\n}"
    try? originalNoChange.write(to: noChangeURL, atomically: true, encoding: .utf8)
    try? HookInstaller.uninstall(settingsURL: noChangeURL)
    check(!FileManager.default.fileExists(atPath: noChangeBakURL.path), "uninstall saat hook tidak terpasang tidak membuat backup")
    let afterNoChange = (try? String(contentsOf: noChangeURL, encoding: .utf8)) ?? ""
    checkEqual(afterNoChange, originalNoChange, "uninstall saat hook tidak terpasang tidak mengubah isi file")

    // 14. Symlink settings.json tidak ditimpa, melainkan menulis ke target (#18)
    let realURL = tempDir.appendingPathComponent("real_settings.json")
    let symlinkURL = tempDir.appendingPathComponent("symlink_settings.json")
    try? "{\n  \"theme\" : \"solarized\"\n}".write(to: realURL, atomically: true, encoding: .utf8)
    try? FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realURL)

    try? HookInstaller.install(settingsURL: symlinkURL, executablePath: appPath)
    let isStillSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path)) != nil
    check(isStillSymlink, "settings.json berupa symlink tetap berupa symlink setelah install")
    let realInstalledContent = (try? String(contentsOf: realURL, encoding: .utf8)) ?? ""
    check(realInstalledContent.contains("--agent-monitor-hook"), "Hook terpasang di target symlink asli")
    let realBakURL = URL(fileURLWithPath: realURL.path + ".agent-monitor.bak")
    check(FileManager.default.fileExists(atPath: realBakURL.path), "Backup dibuat pada target symlink asli")
}

func testClaudeCodeHookStatusAndNeedsPermission() {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent_monitor_claude_status_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let sessionPath = tempDir.appendingPathComponent("session-needs-perm.jsonl").path
    let initialTranscript = ("""
    {"type":"user","message":{"role":"user","content":"Run tests"},"timestamp":"2026-10-16T10:00:00.000Z"}
    {"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"call_1","name":"Bash","input":{"command":"npm test"}}]},"timestamp":"2026-10-16T10:00:01.000Z"}
    """ + "\n").data(using: .utf8)!
    try? initialTranscript.write(to: URL(fileURLWithPath: sessionPath))

    let transcript = ClaudeTranscript(path: sessionPath)
    transcript.update()

    let now = ISODate.parse("2026-10-16T10:00:10.000Z")!
    let lastModified = ISODate.parse("2026-10-16T10:00:01.000Z")!

    // 1. Transcript dengan tool terbuka + event izin yang lebih baru -> .needsPermission dengan detail yang benar
    let permEventNewer = HookPermissionEvent(
        sessionId: "session-needs-perm",
        receivedAt: ISODate.parse("2026-10-16T10:00:03.000Z")!,
        toolName: "Bash",
        toolSummary: "npm test"
    )
    let sPerm = transcript.session(now: now, modified: lastModified, permissionEvent: permEventNewer)
    checkEqual(sPerm?.state, .needsPermission, "Status menjadi .needsPermission ketika event izin lebih baru dari transcript")
    checkEqual(sPerm?.detail, "Minta izin: Bash — npm test", "Detail sesi memformat 'Minta izin: toolName — toolSummary'")
    checkEqual(sPerm?.canDismiss, false, "Sesi .needsPermission tidak dapat ditutup (canDismiss == false)")

    // Notification permission_prompt tanpa tool_name
    let notifEvent = HookPermissionEvent(
        sessionId: "session-needs-perm",
        receivedAt: ISODate.parse("2026-10-16T10:00:03.000Z")!,
        toolName: nil,
        message: "Claude butuh izin untuk melanjutkan"
    )
    let sNotif = transcript.session(now: now, modified: lastModified, permissionEvent: notifEvent)
    checkEqual(sNotif?.state, .needsPermission, "Notification permission_prompt menghasilkan state .needsPermission")
    checkEqual(sNotif?.detail, "Claude butuh izin untuk melanjutkan", "Detail sesi mengambil message dari Notification ketika toolName nil")

    // 2. Event izin lebih lama dari entri terakhir -> bukan .needsPermission
    let permEventOlder = HookPermissionEvent(
        sessionId: "session-needs-perm",
        receivedAt: ISODate.parse("2026-10-16T10:00:00.500Z")!,
        toolName: "Bash",
        toolSummary: "npm test"
    )
    let sOlder = transcript.session(now: now, modified: lastModified, permissionEvent: permEventOlder)
    checkEqual(sOlder?.state, .working, "Event izin yang lebih lama dari entri terakhir tidak memicu .needsPermission")

    // 3. tool_result setelah event izin -> kembali normal
    let toolResultEntry = ("""
    {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_1","content":"All tests passed"}]},"timestamp":"2026-10-16T10:00:05.000Z"}
    """ + "\n").data(using: .utf8)!
    if let handle = FileHandle(forWritingAtPath: sessionPath) {
        handle.seekToEndOfFile()
        handle.write(toolResultEntry)
        try? handle.close()
    }
    transcript.update()

    let afterResultTime = ISODate.parse("2026-10-16T10:00:06.000Z")!
    let sAfterResult = transcript.session(now: afterResultTime, modified: afterResultTime, permissionEvent: permEventNewer)
    check(sAfterResult?.state != .needsPermission, "Setelah tool_result masuk, status kembali normal (bukan .needsPermission)")
    checkEqual(sAfterResult?.state, .working, "Status kembali menjadi .working ('Berpikir...') setelah tool ditutup")

    // 4. Test provider integration: idle_prompt diabaikan dan session_id lain tidak berpengaruh
    let eventsPath = tempDir.appendingPathComponent("events.jsonl").path
    let projectsDir = tempDir.appendingPathComponent("projects")
    let projectSubdir = projectsDir.appendingPathComponent("my-project")
    try? FileManager.default.createDirectory(at: projectSubdir, withIntermediateDirectories: true)

    let activeSessionPath = projectSubdir.appendingPathComponent("active-session.jsonl").path
    try? initialTranscript.write(to: URL(fileURLWithPath: activeSessionPath))

    // Tulis event Notification idle_prompt (harus diabaikan)
    let idlePromptEvent = """
    {"received_at":"2026-10-16T10:00:03.000Z","event":"Notification","session_id":"active-session","notification_type":"idle_prompt","message":"Claude sedang menganggur"}
    """.data(using: .utf8)!
    try? (idlePromptEvent + Data([0x0A])).write(to: URL(fileURLWithPath: eventsPath))

    let provider = ClaudeCodeProvider(root: projectsDir, eventsPath: eventsPath)
    let context1 = PollContext(now: now, processes: [], loop: nil)
    let sessions1 = provider.poll(context1)
    let activeSession1 = sessions1.first { $0.id == "claude:active-session" }
    check(activeSession1?.state != .needsPermission, "Event Notification idle_prompt diabaikan oleh provider")

    // Tulis event PermissionRequest tetapi untuk session_id yang berbeda
    let otherSessionEvent = """
    {"received_at":"2026-10-16T10:00:04.000Z","event":"PermissionRequest","session_id":"different-session","tool_name":"Bash","tool_summary":"git push"}
    """.data(using: .utf8)!
    if let handle = FileHandle(forWritingAtPath: eventsPath) {
        handle.seekToEndOfFile()
        handle.write(otherSessionEvent + Data([0x0A]))
        try? handle.close()
    }

    let sessions2 = provider.poll(context1)
    let activeSession2 = sessions2.first { $0.id == "claude:active-session" }
    check(activeSession2?.state != .needsPermission, "Event izin dari session_id lain tidak mempengaruhi active-session")

    // Sekarang tulis event PermissionRequest untuk active-session
    let targetSessionEvent = """
    {"received_at":"2026-10-16T10:00:05.000Z","event":"PermissionRequest","session_id":"active-session","tool_name":"Bash","tool_summary":"npm test"}
    """.data(using: .utf8)!
    if let handle = FileHandle(forWritingAtPath: eventsPath) {
        handle.seekToEndOfFile()
        handle.write(targetSessionEvent + Data([0x0A]))
        try? handle.close()
    }

    let sessions3 = provider.poll(context1)
    let activeSession3 = sessions3.first { $0.id == "claude:active-session" }
    checkEqual(activeSession3?.state, .needsPermission, "active-session beralih ke .needsPermission setelah event izin yang cocok tiba")

    // 5. Syarat hasOpenTools: event izin lebih baru tetapi tidak ada tool terbuka -> bukan .needsPermission (#23)
    let noToolSessionPath = tempDir.appendingPathComponent("session-no-open-tool.jsonl").path
    let noToolTranscript = ("""
    {"type":"user","message":{"role":"user","content":"Halo"},"timestamp":"2026-10-16T10:00:00.000Z"}
    {"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Halo juga!"}]},"timestamp":"2026-10-16T10:00:02.000Z"}
    """ + "\n").data(using: .utf8)!
    try? noToolTranscript.write(to: URL(fileURLWithPath: noToolSessionPath))

    let transcriptNoTool = ClaudeTranscript(path: noToolSessionPath)
    transcriptNoTool.update()
    let permEventNoTool = HookPermissionEvent(
        sessionId: "session-no-open-tool",
        receivedAt: ISODate.parse("2026-10-16T10:00:03.000Z")!,
        toolName: "Bash",
        toolSummary: "ls"
    )
    let sNoOpenTool = transcriptNoTool.session(
        now: now,
        modified: ISODate.parse("2026-10-16T10:00:02.000Z")!,
        permissionEvent: permEventNoTool
    )
    check(sNoOpenTool?.state != .needsPermission, "Event izin lebih baru tetapi tidak ada tool terbuka -> bukan .needsPermission")
    checkEqual(sNoOpenTool?.state, .waiting, "Sesi tanpa open tools tetap .waiting meskipun ada event izin baru")

    // Verifikasi single source of truth path ~/.agent-monitor (#23)
    checkEqual(MonitorModel.agentMonitorDirectory, HookHandler.defaultDirectory, "MonitorModel menggunakan HookHandler.defaultDirectory")
    check(FileWatcher.defaultDirectories.contains(HookHandler.defaultDirectory), "FileWatcher.defaultDirectories menyertakan HookHandler.defaultDirectory")

    // 6. Uji subdetik: tool_use di …05.800Z dan event di …05.950Z (ditulis via processInput) -> .needsPermission (#17)
    let subsecondSessionPath = projectSubdir.appendingPathComponent("session-subsecond.jsonl").path
    let subsecondTranscriptContent = ("""
    {"type":"user","message":{"role":"user","content":"Run build"},"timestamp":"2026-10-16T10:00:00.000Z"}
    {"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"call_sub_1","name":"Bash","input":{"command":"make build"}}]},"timestamp":"2026-10-16T10:00:05.800Z"}
    """ + "\n").data(using: .utf8)!
    try? subsecondTranscriptContent.write(to: URL(fileURLWithPath: subsecondSessionPath))

    let subsecondPayload = """
    {
      "hook_event_name": "PermissionRequest",
      "session_id": "session-subsecond",
      "cwd": "\(projectSubdir.path)",
      "tool_name": "Bash",
      "tool_input": {
        "command": "make build"
      }
    }
    """.data(using: .utf8)!

    let subsecondEventTime = ISODate.parse("2026-10-16T10:00:05.950Z")!
    HookHandler.processInput(subsecondPayload, receivedAt: subsecondEventTime, directory: tempDir)

    let subsecondPollContext = PollContext(now: ISODate.parse("2026-10-16T10:00:20.000Z")!, processes: [], loop: nil)
    let subsecondSessions = provider.poll(subsecondPollContext)
    let subsecondSession = subsecondSessions.first { $0.id == "claude:session-subsecond" }
    checkEqual(subsecondSession?.state, .needsPermission, "Event izin 05.950Z (via processInput) lebih baru dari tool_use 05.800Z menghasilkan .needsPermission")
}

func testPendingNotificationsDecision() {
    let sWorking = AgentSession(
        id: "s1", kind: .claudeCode, title: "Proyek A", state: .working, detail: "Menjalankan bash"
    )
    let sNeedsPerm = AgentSession(
        id: "s1", kind: .claudeCode, title: "Proyek A", state: .needsPermission, detail: "Minta izin: Bash — npm test"
    )
    let sWaiting = AgentSession(
        id: "s1", kind: .claudeCode, title: "Proyek A", state: .waiting, detail: "Menunggu respons prompt"
    )

    // 1. Pass pertama (primed = false) -> tidak ada notifikasi
    let firstPass = MonitorModel.pendingNotifications(
        currentSessions: [sNeedsPerm],
        previousSessions: ["s1": sWorking],
        currentLoop: nil,
        previousLoopStatus: nil,
        primed: false,
        notificationsOn: true
    )
    check(firstPass.isEmpty, "Pass pertama (primed = false) tidak menghasilkan notifikasi")

    // 2. notificationsOn = false -> tidak ada notifikasi
    let offPass = MonitorModel.pendingNotifications(
        currentSessions: [sNeedsPerm],
        previousSessions: ["s1": sWorking],
        currentLoop: nil,
        previousLoopStatus: nil,
        primed: true,
        notificationsOn: false
    )
    check(offPass.isEmpty, "Saat notificationsOn = false, tidak ada notifikasi")

    // 3. Transisi .working -> .needsPermission -> notifikasi "Claude Code butuh izin"
    let permNotifications = MonitorModel.pendingNotifications(
        currentSessions: [sNeedsPerm],
        previousSessions: ["s1": sWorking],
        currentLoop: nil,
        previousLoopStatus: nil,
        primed: true,
        notificationsOn: true
    )
    checkEqual(permNotifications.count, 1, "Tepat satu notifikasi untuk working -> needsPermission")
    checkEqual(permNotifications.first?.title, "Claude Code butuh izin", "Judul notifikasi 'Claude Code butuh izin'")
    checkEqual(permNotifications.first?.message, "Proyek A: Minta izin: Bash — npm test", "Isi notifikasi '<judul>: <detail>'")

    // 4. Transisi .needsPermission -> .waiting -> notifikasi "Claude Code menunggu Anda"
    let waitFromPermNotifications = MonitorModel.pendingNotifications(
        currentSessions: [sWaiting],
        previousSessions: ["s1": sNeedsPerm],
        currentLoop: nil,
        previousLoopStatus: nil,
        primed: true,
        notificationsOn: true
    )
    checkEqual(waitFromPermNotifications.count, 1, "Tepat satu notifikasi untuk needsPermission -> waiting")
    checkEqual(waitFromPermNotifications.first?.title, "Claude Code menunggu Anda", "Judul notifikasi 'Claude Code menunggu Anda'")
    checkEqual(waitFromPermNotifications.first?.message, "Proyek A: Menunggu respons prompt", "Isi notifikasi '<judul>: <detail>'")

    // 5. Transisi .working -> .waiting -> notifikasi "Claude Code menunggu Anda"
    let waitFromWorkNotifications = MonitorModel.pendingNotifications(
        currentSessions: [sWaiting],
        previousSessions: ["s1": sWorking],
        currentLoop: nil,
        previousLoopStatus: nil,
        primed: true,
        notificationsOn: true
    )
    checkEqual(waitFromWorkNotifications.count, 1, "Tepat satu notifikasi untuk working -> waiting")
    checkEqual(waitFromWorkNotifications.first?.title, "Claude Code menunggu Anda", "Judul notifikasi 'Claude Code menunggu Anda'")
}

func testAgentStateAndCanDismiss() {
    // 1. Urutan state: needsPermission paling atas
    check(AgentState.needsPermission < AgentState.waiting, ".needsPermission lebih prioritas dari .waiting")
    check(AgentState.waiting < AgentState.working, ".waiting lebih prioritas dari .working")
    checkEqual(AgentState.needsPermission.rawValue, 0, "RawValue .needsPermission adalah 0 (teratas)")

    // 2. Label
    checkEqual(AgentState.needsPermission.label, "Butuh izin", "Label .needsPermission adalah 'Butuh izin'")

    // 3. canDismiss
    let sPerm = AgentSession(id: "1", kind: .claudeCode, title: "T", state: .needsPermission)
    checkEqual(sPerm.canDismiss, false, "canDismiss bernilai false untuk .needsPermission")

    let sWork = AgentSession(id: "2", kind: .claudeCode, title: "T", state: .working)
    checkEqual(sWork.canDismiss, false, "canDismiss bernilai false untuk .working")

    let sWait = AgentSession(id: "3", kind: .claudeCode, title: "T", state: .waiting)
    checkEqual(sWait.canDismiss, true, "canDismiss bernilai true untuk .waiting")

    let sIdle = AgentSession(id: "4", kind: .claudeCode, title: "T", state: .idle)
    checkEqual(sIdle.canDismiss, true, "canDismiss bernilai true untuk .idle")

    let sFinished = AgentSession(id: "5", kind: .claudeCode, title: "T", state: .finished)
    checkEqual(sFinished.canDismiss, true, "canDismiss bernilai true untuk .finished")

    let sFailed = AgentSession(id: "6", kind: .claudeCode, title: "T", state: .failed)
    checkEqual(sFailed.canDismiss, true, "canDismiss bernilai true untuk .failed")

    let sRunning = AgentSession(id: "7", kind: .claudeCode, title: "T", state: .running)
    checkEqual(sRunning.canDismiss, true, "canDismiss bernilai true untuk .running")
}

func testSessionJumper() {
    let syntheticPs = """
        1     0 ??       /sbin/launchd
      700     1 ??       /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
      701   700 ttys003  /usr/bin/login
      702   701 ttys003  -zsh
      703   702 ttys003  /Users/dev/.local/bin/claude
      800     1 ??       /Applications/iTerm.app/Contents/MacOS/iTerm2
      801   800 ttys005  -zsh
      802   801 ttys005  /opt/homebrew/bin/codex
      900     1 ??       /Applications/Visual Studio Code.app/Contents/MacOS/Electron
      901   900 ??       /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)
      902   901 ??       /Users/dev/.vscode/extensions/anthropic.claude-code-2.1.0-darwin-arm64/resources/native-binary/claude
      950     1 ??       /Applications/Cursor.app/Contents/MacOS/Cursor
      951   950 ??       /Users/dev/.cursor/extensions/anthropic.claude-code/claude
      600     1 ??       /usr/sbin/cron
      601   600 ??       /usr/local/bin/claude
    """

    // 1. Parsing output ps menjadi tree
    let tree = SessionJumper.parseProcessTree(syntheticPs)
    checkEqual(tree.count, 15, "Seluruh 15 baris ps sintetis berhasil di-parse")
    checkEqual(tree[703]?.comm, "/Users/dev/.local/bin/claude", "comm proses 703 terbaca benar")
    checkEqual(tree[703]?.ppid, 702, "ppid proses 703 adalah 702")
    checkEqual(tree[703]?.tty, "ttys003", "tty proses 703 adalah ttys003")
    checkEqual(tree[902]?.tty, nil, "tty '??' disimpan sebagai nil")

    // 2. Outermost .app bundle path extractor
    let nestedPath = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
    checkEqual(SessionJumper.outermostAppPath(from: nestedPath), "/Applications/Visual Studio Code.app", "Mengambil bundle .app terluar dari path bersarang")
    checkEqual(SessionJumper.outermostAppPath(from: "-zsh"), nil, "Bukan path .app menghasilkan nil")

    // 3. Menelusuri rantai parent untuk menemukan host .app
    // Kasus 1: Terminal
    let hostTerminal = SessionJumper.findHostApp(for: 703, in: tree)
    checkEqual(hostTerminal?.bundleId, "com.apple.Terminal", "Host untuk proses 703 adalah com.apple.Terminal")
    checkEqual(hostTerminal?.appPath, "/System/Applications/Utilities/Terminal.app", "Path host Terminal benar")
    checkEqual(hostTerminal?.pid, 700, "PID host Terminal adalah 700")

    // Kasus 2: iTerm2
    let hostIterm = SessionJumper.findHostApp(for: 802, in: tree)
    checkEqual(hostIterm?.bundleId, "com.googlecode.iterm2", "Host untuk proses 802 adalah com.googlecode.iterm2")
    checkEqual(hostIterm?.appPath, "/Applications/iTerm.app", "Path host iTerm2 benar")
    checkEqual(hostIterm?.pid, 800, "PID host iTerm2 adalah 800")

    // Kasus 3: VS Code (proses ekstensi tanpa TTY)
    let hostVSCode = SessionJumper.findHostApp(for: 902, in: tree)
    checkEqual(hostVSCode?.bundleId, "com.microsoft.VSCode", "Host untuk proses 902 adalah com.microsoft.VSCode")
    checkEqual(hostVSCode?.appPath, "/Applications/Visual Studio Code.app", "Path host VS Code benar")
    checkEqual(hostVSCode?.pid, 900, "PID host VS Code terluar adalah 900")

    // Kasus Cursor
    let hostCursor = SessionJumper.findHostApp(for: 951, in: tree)
    checkEqual(hostCursor?.bundleId, "com.todesktop.230313mzl4w4u92", "Host untuk proses 951 adalah Cursor bundle ID")
    checkEqual(hostCursor?.appPath, "/Applications/Cursor.app", "Path host Cursor benar")

    // Kasus 4: Tidak ada host (cron / daemon)
    let hostNone = SessionJumper.findHostApp(for: 601, in: tree)
    check(hostNone == nil, "Proses tanpa host .app menghasilkan host nil")

    // 4. Pencocokan sesi dengan proses berdasarkan cwd
    let project = "/Users/dev/contoh-proyek"
    check(SessionJumper.matchesProject(processCwd: "/Users/dev/contoh-proyek", projectPath: project), "cwd persis sama cocok")
    check(SessionJumper.matchesProject(processCwd: "/Users/dev/contoh-proyek/src/nested", projectPath: project), "cwd di dalam subfolder cocok")
    check(!SessionJumper.matchesProject(processCwd: "/Users/dev/contoh-proyek-2", projectPath: project), "cwd prefix mirip tetapi beda folder tidak cocok")
    check(!SessionJumper.matchesProject(processCwd: "/Users/dev/proyek-lain", projectPath: project), "cwd berbeda tidak cocok")

    // Beberapa kandidat: yang ber-TTY dipilih
    let candNoTTY = ProcessTreeEntry(pid: 101, ppid: 1, tty: nil, comm: "/usr/local/bin/claude")
    let candWithTTY = ProcessTreeEntry(pid: 102, ppid: 1, tty: "ttys003", comm: "/usr/local/bin/claude")
    let bestCand = SessionJumper.pickBestProcess(
        candidates: [candNoTTY, candWithTTY],
        projectPath: project,
        cwdSupplier: { _ in project }
    )
    checkEqual(bestCand?.pid, 102, "Kandidat dengan TTY diprioritaskan saat keduanya cocok cwd")

    // 5. String AppleScript untuk Terminal dan iTerm2
    let termScript = SessionJumper.terminalAppleScript(for: "ttys003")
    check(termScript.contains("\"/dev/ttys003\""), "AppleScript Terminal memuat TTY berformat /dev/ttys003")
    check(termScript.contains("set selected of t to true"), "AppleScript Terminal memilih tab")
    check(termScript.contains("set index of w to 1"), "AppleScript Terminal memajukan jendela")

    let itermScript = SessionJumper.itermAppleScript(for: "ttys005")
    check(itermScript.contains("\"/dev/ttys005\""), "AppleScript iTerm2 memuat TTY berformat /dev/ttys005")
    check(itermScript.contains("select t"), "AppleScript iTerm2 memilih tab")
    check(itermScript.contains("select s"), "AppleScript iTerm2 memilih session")

    // Keamanan terhadap tanda kutip
    let quoteEscapedScript = SessionJumper.terminalAppleScript(for: "ttys\"001")
    check(quoteEscapedScript.contains("/dev/ttys\\\"001"), "Tanda kutip ganda di TTY di-escape dengan aman")

    // 6. Pemilihan aksi (determineAction)
    // Terminal + TTY
    let actTerm = SessionJumper.determineAction(host: hostTerminal, tty: "ttys003", projectPath: project)
    if case .terminal(let s) = actTerm {
        check(s.contains("/dev/ttys003"), "Aksi Terminal menghasilkan .terminal dengan script")
    } else {
        check(false, "Ekspektasi aksi .terminal")
    }

    // iTerm2 + TTY
    let actIterm = SessionJumper.determineAction(host: hostIterm, tty: "ttys005", projectPath: project)
    if case .iterm(let s) = actIterm {
        check(s.contains("/dev/ttys005"), "Aksi iTerm2 menghasilkan .iterm dengan script")
    } else {
        check(false, "Ekspektasi aksi .iterm")
    }

    // Terminal tanpa TTY -> activateApp
    let actTermNoTTY = SessionJumper.determineAction(host: hostTerminal, tty: nil, projectPath: project)
    checkEqual(actTermNoTTY, .activateApp(pid: 700), "Terminal tanpa TTY menghasilkan .activateApp")

    // iTerm2 tanpa TTY -> activateApp
    let actItermNoTTY = SessionJumper.determineAction(host: hostIterm, tty: nil, projectPath: project)
    checkEqual(actItermNoTTY, .activateApp(pid: 800), "iTerm2 tanpa TTY menghasilkan .activateApp")

    // VS Code -> openProject
    let actVSCode = SessionJumper.determineAction(host: hostVSCode, tty: nil, projectPath: project)
    checkEqual(actVSCode, .openProject(bundleId: "com.microsoft.VSCode", path: project), "VS Code menghasilkan .openProject dengan bundle id com.microsoft.VSCode")

    // Cursor -> openProject
    let actCursor = SessionJumper.determineAction(host: hostCursor, tty: nil, projectPath: project)
    checkEqual(actCursor, .openProject(bundleId: "com.todesktop.230313mzl4w4u92", path: project), "Cursor menghasilkan .openProject dengan bundle id Cursor")

    // Host lain -> activateApp
    let otherHost = HostAppInfo(pid: 300, bundleId: "com.alacritty", appPath: "/Applications/Alacritty.app")
    let actOther = SessionJumper.determineAction(host: otherHost, tty: nil, projectPath: project)
    checkEqual(actOther, .activateApp(pid: 300), "Host lain menghasilkan .activateApp")

    // Host nil / tidak ditemukan -> notFound
    let actNotFound = SessionJumper.determineAction(host: nil, tty: nil, projectPath: project)
    checkEqual(actNotFound, .notFound, "Host nil menghasilkan .notFound")

    // 7. resolveAction dengan injeksi supplier (tanpa memanggil proses sungguhan)
    let cwds: [Int: String] = [
        703: project,
        802: project,
        902: project,
        951: project
    ]
    let resolvedTerm = SessionJumper.resolveAction(
        forKind: .claudeCode,
        projectPath: project,
        processTreeSupplier: { syntheticPs },
        cwdSupplier: { cwds[$0] }
    )
    if case .terminal = resolvedTerm {
        check(true, "resolveAction berhasil mendeteksi Terminal via supplier injeksi")
    } else {
        check(false, "resolveAction gagal mendeteksi Terminal")
    }

    let resolvedCodex = SessionJumper.resolveAction(
        forKind: .codex,
        projectPath: project,
        processTreeSupplier: { syntheticPs },
        cwdSupplier: { cwds[$0] }
    )
    if case .iterm = resolvedCodex {
        check(true, "resolveAction berhasil mendeteksi iTerm2 untuk Codex via supplier injeksi")
    } else {
        check(false, "resolveAction gagal mendeteksi iTerm2")
    }

    let resolvedNotFound = SessionJumper.resolveAction(
        forKind: .claudeCode,
        projectPath: "/Users/dev/unmatched-project",
        processTreeSupplier: { syntheticPs },
        cwdSupplier: { cwds[$0] }
    )
    checkEqual(resolvedNotFound, .notFound, "resolveAction menghasilkan .notFound jika tidak ada proses cocok")

    // 8. canJump property
    let sClaude = AgentSession(id: "c1", kind: .claudeCode, title: "Claude", project: project, state: .working)
    check(sClaude.canJump, "canJump bernilai true untuk Claude Code dengan project")
    let sCodex = AgentSession(id: "x1", kind: .codex, title: "Codex", project: project, state: .waiting)
    check(sCodex.canJump, "canJump bernilai true untuk Codex dengan project")
    let sNoProj = AgentSession(id: "c2", kind: .claudeCode, title: "Claude", project: nil, state: .running)
    check(!sNoProj.canJump, "canJump bernilai false jika project nil")
    let sGemini = AgentSession(id: "g1", kind: .geminiCLI, title: "Gemini", project: project, state: .working)
    check(!sGemini.canJump, "canJump bernilai false untuk Gemini CLI")
    let sOllama = AgentSession(id: "o1", kind: .ollama, title: "Ollama", state: .running)
    check(!sOllama.canJump, "canJump bernilai false untuk Ollama")
}

func testNotificationActions() {
    // 1. Pemilihan kategori untuk setiap kombinasi state × canJump
    // - .needsPermission
    let itemPermJump = MonitorModel.NotificationItem(
        title: "Claude Code butuh izin", message: "detail", agentId: "c1", kind: .claudeCode, state: .needsPermission, canJump: true
    )
    checkEqual(Notifier.categoryIdentifier(for: itemPermJump), NotificationCategoryIdentifier.needsPermissionJump, "Kategori .needsPermission + canJump adalah needsPermissionJump")

    let itemPermNoJump = MonitorModel.NotificationItem(
        title: "Claude Code butuh izin", message: "detail", agentId: "c1", kind: .claudeCode, state: .needsPermission, canJump: false
    )
    checkEqual(Notifier.categoryIdentifier(for: itemPermNoJump), NotificationCategoryIdentifier.needsPermissionNoJump, "Kategori .needsPermission + noJump adalah needsPermissionNoJump")

    // - .waiting
    let itemWaitJump = MonitorModel.NotificationItem(
        title: "Claude Code menunggu Anda", message: "detail", agentId: "c1", kind: .claudeCode, state: .waiting, canJump: true
    )
    checkEqual(Notifier.categoryIdentifier(for: itemWaitJump), NotificationCategoryIdentifier.actionableJump, "Kategori .waiting + canJump adalah actionableJump")

    let itemWaitNoJump = MonitorModel.NotificationItem(
        title: "Claude Code menunggu Anda", message: "detail", agentId: "c1", kind: .claudeCode, state: .waiting, canJump: false
    )
    checkEqual(Notifier.categoryIdentifier(for: itemWaitNoJump), NotificationCategoryIdentifier.actionableNoJump, "Kategori .waiting + noJump adalah actionableNoJump")

    // - .failed
    let itemFailJump = MonitorModel.NotificationItem(
        title: "Claude Code error", message: "detail", agentId: "c1", kind: .claudeCode, state: .failed, canJump: true
    )
    checkEqual(Notifier.categoryIdentifier(for: itemFailJump), NotificationCategoryIdentifier.actionableJump, "Kategori .failed + canJump adalah actionableJump")

    let itemFailNoJump = MonitorModel.NotificationItem(
        title: "Claude Code error", message: "detail", agentId: "c1", kind: .claudeCode, state: .failed, canJump: false
    )
    checkEqual(Notifier.categoryIdentifier(for: itemFailNoJump), NotificationCategoryIdentifier.actionableNoJump, "Kategori .failed + noJump adalah actionableNoJump")

    // - .finished
    let itemFinJump = MonitorModel.NotificationItem(
        title: "Claude Code selesai", message: "detail", agentId: "c1", kind: .claudeCode, state: .finished, canJump: true
    )
    checkEqual(Notifier.categoryIdentifier(for: itemFinJump), NotificationCategoryIdentifier.actionableJump, "Kategori .finished + canJump adalah actionableJump")

    let itemFinNoJump = MonitorModel.NotificationItem(
        title: "Claude Code selesai", message: "detail", agentId: "c1", kind: .claudeCode, state: .finished, canJump: false
    )
    checkEqual(Notifier.categoryIdentifier(for: itemFinNoJump), NotificationCategoryIdentifier.actionableNoJump, "Kategori .finished + noJump adalah actionableNoJump")

    // - .working, .idle, .running -> tanpa aksi (nil)
    for state in [AgentState.working, AgentState.idle, AgentState.running] {
        let itJump = MonitorModel.NotificationItem(
            title: "T", message: "M", agentId: "c1", kind: .claudeCode, state: state, canJump: true
        )
        let itNoJump = MonitorModel.NotificationItem(
            title: "T", message: "M", agentId: "c1", kind: .claudeCode, state: state, canJump: false
        )
        checkEqual(Notifier.categoryIdentifier(for: itJump), nil, "Kategori state \(state) + canJump adalah nil")
        checkEqual(Notifier.categoryIdentifier(for: itNoJump), nil, "Kategori state \(state) + noJump adalah nil")
    }

    // - Loop notification -> tanpa aksi (nil)
    let itemLoop = MonitorModel.NotificationItem(
        title: "Loop my-project: Claude", message: "subtitle", agentId: nil, kind: nil, state: nil, canJump: false
    )
    checkEqual(Notifier.categoryIdentifier(for: itemLoop), nil, "Kategori notifikasi loop adalah nil")

    // - Gemini CLI berhenti -> tanpa aksi (nil)
    let itemGeminiStop = MonitorModel.NotificationItem(
        title: "Gemini CLI berhenti", message: "prompt", agentId: "g1", kind: .geminiCLI, state: nil, canJump: false
    )
    checkEqual(Notifier.categoryIdentifier(for: itemGeminiStop), nil, "Kategori 'Gemini CLI berhenti' adalah nil")

    // 2. Pemetaan identifier aksi (resolveAction)
    // - Buka ("open")
    checkEqual(Notifier.resolveAction(actionIdentifier: NotificationActionIdentifier.open, agentId: "c1", canJump: true), .jump(agentId: "c1"), "Action 'open' dengan canJump true menghasilkan .jump")
    checkEqual(Notifier.resolveAction(actionIdentifier: NotificationActionIdentifier.open, agentId: "c1", canJump: false), .openPanel, "Action 'open' dengan canJump false menghasilkan .openPanel")
    checkEqual(Notifier.resolveAction(actionIdentifier: NotificationActionIdentifier.open, agentId: nil, canJump: false), .openPanel, "Action 'open' tanpa agentId menghasilkan .openPanel")

    // - Klik pada isi notifikasi (UNNotificationDefaultActionIdentifier)
    checkEqual(Notifier.resolveAction(actionIdentifier: UNNotificationDefaultActionIdentifier, agentId: "c1", canJump: true), .jump(agentId: "c1"), "Default action dengan canJump true menghasilkan .jump")
    checkEqual(Notifier.resolveAction(actionIdentifier: UNNotificationDefaultActionIdentifier, agentId: "c1", canJump: false), .openPanel, "Default action dengan canJump false menghasilkan .openPanel")
    checkEqual(Notifier.resolveAction(actionIdentifier: UNNotificationDefaultActionIdentifier, agentId: nil, canJump: false), .openPanel, "Default action tanpa agentId menghasilkan .openPanel")

    // - Tunda 10 mnt ("snooze")
    checkEqual(Notifier.resolveAction(actionIdentifier: NotificationActionIdentifier.snooze, agentId: "c1", canJump: true), .snooze(agentId: "c1"), "Action 'snooze' dengan agentId menghasilkan .snooze")
    checkEqual(Notifier.resolveAction(actionIdentifier: NotificationActionIdentifier.snooze, agentId: nil, canJump: false), .none, "Action 'snooze' tanpa agentId menghasilkan .none")

    // - Tutup pantauan ("dismiss")
    checkEqual(Notifier.resolveAction(actionIdentifier: NotificationActionIdentifier.dismiss, agentId: "c1", canJump: true), .dismiss(agentId: "c1"), "Action 'dismiss' dengan agentId menghasilkan .dismiss")
    checkEqual(Notifier.resolveAction(actionIdentifier: NotificationActionIdentifier.dismiss, agentId: nil, canJump: false), .none, "Action 'dismiss' tanpa agentId menghasilkan .none")

    // - Identifier tak dikenal & swipe away -> .none
    checkEqual(Notifier.resolveAction(actionIdentifier: "unknown_identifier", agentId: "c1", canJump: true), .none, "Identifier tak dikenal menghasilkan .none")
    checkEqual(Notifier.resolveAction(actionIdentifier: UNNotificationDismissActionIdentifier, agentId: "c1", canJump: true), .none, "Dismiss identifier sistem menghasilkan .none")

    // - Pemetaan via userInfo
    checkEqual(Notifier.resolveAction(actionIdentifier: NotificationActionIdentifier.open, userInfo: ["agentId": "c1", "canJump": true]), .jump(agentId: "c1"), "resolveAction via userInfo untuk 'open' + canJump")
    checkEqual(Notifier.resolveAction(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: ["agentId": "c1", "canJump": false]), .openPanel, "resolveAction via userInfo untuk default action + noJump")
    checkEqual(Notifier.resolveAction(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: [:]), .openPanel, "resolveAction via userInfo kosong untuk default action")
    checkEqual(Notifier.resolveAction(actionIdentifier: NotificationActionIdentifier.snooze, userInfo: ["agentId": "c1"]), .snooze(agentId: "c1"), "resolveAction via userInfo untuk 'snooze'")
    checkEqual(Notifier.resolveAction(actionIdentifier: NotificationActionIdentifier.dismiss, userInfo: ["agentId": "c1"]), .dismiss(agentId: "c1"), "resolveAction via userInfo untuk 'dismiss'")
    checkEqual(Notifier.resolveAction(actionIdentifier: "unknown", userInfo: ["agentId": "c1"]), .none, "resolveAction via userInfo untuk aksi tak dikenal")

    // 3. pendingNotifications dengan snooze
    let now = Date(timeIntervalSince1970: 1700000000)
    let sWorking1 = AgentSession(id: "s1", kind: .claudeCode, title: "Proyek A", state: .working)
    let sNeedsPerm1 = AgentSession(id: "s1", kind: .claudeCode, title: "Proyek A", state: .needsPermission, detail: "Izin Bash")
    let sWorking2 = AgentSession(id: "s2", kind: .codex, title: "Proyek B", state: .working)
    let sWaiting2 = AgentSession(id: "s2", kind: .codex, title: "Proyek B", state: .waiting, detail: "Menunggu masukan")

    let loopJSON = """
    {"project":"/Users/dev/proj","phase":"1","round":1,"status":"gemini","description":"Test"}
    """
    let loopState2 = try! JSONDecoder().decode(LoopState.self, from: Data(loopJSON.utf8))
    let loop2 = LoopSnapshot(state: loopState2)

    // - S1 ditunda selama 10 menit (600 dtk)
    let snoozedMap = ["s1": now.addingTimeInterval(600)]

    let notificationsNow = MonitorModel.pendingNotifications(
        currentSessions: [sNeedsPerm1, sWaiting2],
        previousSessions: ["s1": sWorking1, "s2": sWorking2],
        currentLoop: loop2,
        previousLoopStatus: "claude",
        primed: true,
        notificationsOn: true,
        snoozedUntil: snoozedMap,
        now: now
    )

    check(!notificationsNow.contains { $0.agentId == "s1" }, "Agen s1 yang ditunda tidak menghasilkan notifikasi pada waktu sekarang")
    check(notificationsNow.contains { $0.agentId == "s2" }, "Agen s2 yang tidak ditunda tetap menghasilkan notifikasi")
    check(notificationsNow.contains { $0.agentId == nil }, "Notifikasi loop tetap dihasilkan meski ada agen yang ditunda")

    // - Setelah 10 menit berlalu (now + 601 detik), s1 menghasilkan notifikasi lagi
    let nowAfter10 = now.addingTimeInterval(601)
    let notificationsAfter = MonitorModel.pendingNotifications(
        currentSessions: [sNeedsPerm1, sWaiting2],
        previousSessions: ["s1": sWorking1, "s2": sWorking2],
        currentLoop: loop2,
        previousLoopStatus: "claude",
        primed: true,
        notificationsOn: true,
        snoozedUntil: snoozedMap,
        now: nowAfter10
    )

    check(notificationsAfter.contains { $0.agentId == "s1" }, "Setelah 10 menit berlalu, agen s1 menghasilkan notifikasi lagi")
    check(notificationsAfter.contains { $0.agentId == "s2" }, "Agen s2 tetap menghasilkan notifikasi setelah 10 menit")
    check(notificationsAfter.contains { $0.agentId == nil }, "Notifikasi loop tetap ada")

    // 4. agentId dan threadIdentifier di NotificationItem
    let itemS1 = notificationsAfter.first { $0.agentId == "s1" }
    check(itemS1?.agentId == "s1", "agentId pada item bernilai 's1'")
    checkEqual(itemS1?.threadIdentifier, "s1", "threadIdentifier pada item agen bernilai 's1'")

    let itemLoopFound = notificationsAfter.first { $0.agentId == nil }
    check(itemLoopFound?.agentId == nil, "agentId pada item loop bernilai nil")
    checkEqual(itemLoopFound?.threadIdentifier, "loop", "threadIdentifier pada item loop bernilai 'loop'")

    // 5. Verifikasi kategori dan aksi sistem
    let categories = Notifier.makeCategories()
    checkEqual(categories.count, 4, "Terdapat tepat 4 kategori notifikasi yang didaftarkan")
    let catIds = Set(categories.map(\.identifier))
    check(catIds.contains(NotificationCategoryIdentifier.needsPermissionJump), "Kategori needsPermissionJump terdaftar")
    check(catIds.contains(NotificationCategoryIdentifier.needsPermissionNoJump), "Kategori needsPermissionNoJump terdaftar")
    check(catIds.contains(NotificationCategoryIdentifier.actionableJump), "Kategori actionableJump terdaftar")
    check(catIds.contains(NotificationCategoryIdentifier.actionableNoJump), "Kategori actionableNoJump terdaftar")
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
runSuite("TranscriptActivityLog", testTranscriptActivityLog)
runSuite("PresenceProvider", testPresenceProvider)
runSuite("Ollama Parsing", testOllamaParsing)
await runSuiteAsync("PollingEngine", testPollingEngine)
await runSuiteAsync("FileWatcher", testFileWatcher)
runSuite("HookHandler & Mode Hook", testHookHandler)
runSuite("HookInstaller", testHookInstaller)
runSuite("ClaudeCode Hook Status & needsPermission", testClaudeCodeHookStatusAndNeedsPermission)
runSuite("Pending Notifications Decision", testPendingNotificationsDecision)
runSuite("AgentState & canDismiss", testAgentStateAndCanDismiss)
runSuite("SessionJumper & Lompat ke Sesi", testSessionJumper)
runSuite("Aksi Notifikasi & Kategori", testNotificationActions)

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
