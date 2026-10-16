# Agent Monitor

Aplikasi menu bar macOS native (SwiftUI + AppKit, tanpa dependensi pihak ketiga) untuk memantau aktivitas, status, konsumsi token/biaya, dan batas kuota berbagai agen AI lokal (Claude Code, Codex, Gemini CLI / `agy`, Ollama, dan lainnya) secara real-time dan terpadu.

---

## Fitur Utama

- **Pemantauan Agen Real-Time**:
  - Membaca transcript JSONL inkremental dari Claude Code (`~/.claude/projects`) dan Codex (`~/.codex/sessions`).
  - Membaca stream-json log dari Gemini CLI (`agy`).
  - Mendeteksi proses AI lokal di macOS via `ps` dan model Ollama via endpoint HTTP lokal.
  - Menampilkan status agen: **Menunggu Anda**, **Bekerja**, **Selesai**, **Error**, **Diam**, atau **Terbuka**.
- **Aktivitas Detail Sesi**:
  - Rekaman riwayat aktivitas per tool call (baca file, edit, perintah bash/terminal, pencarian, web browser).
  - Durasi eksekusi per tool dan token yang digunakan.
- **Monitoring Kuota & Model**:
  - Mengambil batas kuota rencana akun (Claude & Codex) berkala dengan penanganan throttle dan cache cerdas.
  - Informasi model default serta model yang sedang aktif digunakan di setiap sesi.
- **Integrasi Aegis Loop (Gemini ↔ Claude)**:
  - Pelacakan status putaran loop review (`state.json` di `~/.aegis-loop`).
  - Pemantauan perubahan berkas working-tree git (`git status` & `git diff`).
  - Penghitungan temuan di `REVIEW.md` (Terbuka, Diperbaiki, Ditolak).
- **Floating Panel & Menu Bar**:
  - Menu bar ekstra yang ringkas dengan badge indikator jumlah agen yang menunggu respons Anda atau sedang bekerja.
  - Floating panel yang dapat ditempel di atas jendela lain tanpa mengambil fokus kerja.
- **Mode CLI Debug**:
  - Opsi `--dump` untuk mencetak snapshot kondisi seluruh agen langsung ke terminal tanpa membuka UI.

---

## Struktur Proyek

```
agent-monitor/
├── Package.swift                    # Konfigurasi Swift Package Manager
├── Sources/
│   ├── AgentMonitor/               # Target aplikasi executable (menu bar AppKit/SwiftUI)
│   │   └── AgentMonitorApp.swift
│   ├── AgentMonitorKit/            # Pustaka inti bersama (core logic & UI views)
│   │   ├── Models.swift            # Model data agen, status, aktivitas, dan loop
│   │   ├── Support.swift           # JSONLTail reader, ISO date formatter, Format helper
│   │   ├── StreamReader.swift      # Parser log stream-json agy (Gemini)
│   │   ├── AegisLoop.swift         # Integrasi loop koordinasi Aegis
│   │   ├── LoopControl.swift       # Runner sesi headless & permission store
│   │   ├── MonitorModel.swift      # State model observable utama
│   │   ├── FloatingPanel.swift     # Window panel macOS utilitas
│   │   ├── Views.swift             # Komponen SwiftUI monitor, usage, model, dan tab
│   │   ├── LoopTab.swift           # Tampilan tab Aegis loop
│   │   ├── Notifier.swift          # Notifikasi user macOS
│   │   ├── Shell.swift             # Helper eksekusi command line macOS
│   │   └── Providers/              # Provider spesifik tiap agen
│   │       ├── ClaudeCodeProvider.swift
│   │       ├── ClaudeUsageProvider.swift
│   │       ├── CodexProvider.swift
│   │       ├── CodexUsageProvider.swift
│   │       ├── GeminiProvider.swift
│   │       ├── ModelCatalog.swift
│   │       └── PresenceProvider.swift
│   └── AgentMonitorChecks/         # Target executable uji otomatis (test suite)
│       └── main.swift
├── Tests/
│   └── Fixtures/                   # Berkas log sintetis untuk pengujian parser
│       ├── claude_session.jsonl
│       ├── codex_rollout.jsonl
│       ├── agy_stream.jsonl
│       ├── agy_stream_denied.jsonl
│       ├── REVIEW.md
│       └── aegis_state.json
├── Resources/
│   └── Info.plist
├── AGENTS.md                       # Aturan kerja kolaborasi AI (Gemini builder + Claude reviewer)
├── HANDOFF.md                      # Log handoff hasil pengerjaan putaran
├── REVIEW.md                       # Catatan review temuan Claude
└── saran-pengembangan.md           # Rencana peta jalan pengembangan aplikasi
```

---

## Persyaratan Sistem

- macOS 13.0 (Ventura) atau lebih baru
- Command Line Tools untuk Xcode / Swift 5.9+ (tanpa dependensi eksternal)

---

## Kompilasi dan Pengujian

### 1. Build Debug & Release

```sh
# Build mode debug
swift build

# Build mode release
swift build -c release
```

### 2. Menjalankan Uji Otomatis (Checks)

Karena toolchain macOS Command Line Tools tidak menyertakan Xcode testing bundle penuh, pengujian dijalankan sebagai executable target tersendiri berbasis fixture sintetis:

```sh
swift run AgentMonitorChecks
```

### 3. Debug dari Terminal (--dump)

Untuk melihat ringkasan status sesi yang terdeteksi tanpa membuka menu bar:

```sh
swift run AgentMonitor --dump
```

### 4. Pemasangan Aplikasi ke Sistem

Skrip `build.sh` membangun binari release, menyalin bundle aplikasi ke `~/Applications/Agent Monitor.app`, dan meluncurkannya:

```sh
./build.sh
```

*(Catatan: Sesuai aturan kerja proyek, skrip `build.sh` hanya dijalankan oleh user atau reviewer karena me-restart aplikasi).*

---

## Alur Kerja Pengembangan

Proyek ini dikembangkan menggunakan kolaborasi dua agen AI sesuai `AGENTS.md`:
1. **Gemini (Antigravity)** bertindak sebagai pembuat kode (*builder*).
2. **Claude Code** bertindak sebagai peninjau kode (*reviewer*).
3. Pemilik proyek (*User*) memutuskan arah pengembangan dan melakukan commit git.
