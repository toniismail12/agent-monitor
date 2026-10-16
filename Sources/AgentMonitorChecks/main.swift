import Foundation
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
