# Aturan kerja project agent-monitor

Project ini dikerjakan oleh dua agen AI dengan peran terpisah:

- **Gemini (Antigravity): pembuat.** Menulis kode dan mengerjakan tugas dari user.
- **Claude Code: reviewer.** Memeriksa hasil kerja Gemini dan tidak menulis kode fitur.

User (pemilik project) yang memberi tugas, memutuskan kalau ada beda pendapat, dan meng-commit.

Rencana kerjanya ada di `saran-pengembangan.md`, bagian "Usulan urutan pengerjaan". Satu putaran mengerjakan satu tahap atau bagian dari tahap.

## Stack

- Aplikasi menu bar macOS 13+, SwiftUI + AppKit, Swift Package Manager, **tanpa dependensi pihak ketiga** kecuali disetujui user.
- Toolchain di Mac ini hanya **Command Line Tools (Swift 5.10), tanpa Xcode**. Akibatnya XCTest dan swift-testing **tidak tersedia**, sehingga `swift test` tidak bisa dipakai. Test dijalankan sebagai executable: `swift run AgentMonitorChecks`.
- Komentar kode dalam bahasa Inggris, teks yang dilihat user dalam bahasa Indonesia. Ikuti gaya kode yang sudah ada.

## Alur satu putaran

1. User memberi tugas. Claude meneruskannya ke Gemini sebagai prompt.
2. Gemini mengerjakan, lalu mengisi bagian "Putaran terbaru" di `HANDOFF.md`.
3. Gemini berhenti **tanpa commit**. Claude menyimpan kondisi yang sudah disetujui di git index (`git add`), sehingga perubahan putaran berikutnya terlihat lewat `git diff`.
4. Claude me-review dan menulis temuannya di `REVIEW.md`.
5. Gemini membaca `REVIEW.md`, memperbaiki, lalu mengisi status dan tanggapan untuk setiap temuan. `HANDOFF.md` juga diperbarui.
6. Langkah 4–5 diulang sampai tidak ada temuan yang masih terbuka. Setelah itu user commit.

## Uji wajib setiap putaran

Jalankan dari root project dan tempel output ringkasnya di `HANDOFF.md`:

```sh
swift build
swift build -c release
swift run AgentMonitorChecks
```

Jangan menjalankan `build.sh`. Script itu mematikan aplikasi yang sedang dipakai user lalu memasang ulang, jadi hanya Claude atau user yang menjalankannya.

## Aturan untuk Gemini

- Perintah yang diizinkan di sesi headless hanya: `swift`, `git status`, `git diff`, `git log`, `ls`, `cat`, `head`, `tail`, `wc`, `find`, `grep`, `mkdir`, `mv`, `cp`, `touch`, `pwd`, `which`, `echo`, `sleep`. Perintah lain (termasuk `rm`, `kill`, `git add`/`commit`/`mv`) akan ditolak dan seluruh sesi ikut berhenti. Kalau butuh sesuatu di luar daftar ini, tulis kebutuhannya di `HANDOFF.md`.
- Jangan menjalankan perintah git yang mengubah state (`add`, `commit`, `push`, `reset`, `stash`, `checkout`, `restore`, `mv`, `rm`).
- Hanya bekerja di dalam folder project. Jangan membaca `~/.claude`, `~/.codex`, `~/.gemini`, atau folder lain di luar project.
- Fixture test harus **sintetis**. Jangan menyalin isi transcript sungguhan (prompt, kode, path pribadi). Pakai path contoh seperti `/Users/dev/contoh-proyek`.
- Di `REVIEW.md`, yang boleh diisi hanya kolom **Status** dan **Tanggapan** setiap temuan.
- Satu putaran untuk satu tugas yang jelas. Jangan menyelipkan perubahan yang tidak diminta.
- Kalau menurutmu sebuah temuan salah, set statusnya `Ditolak` dan tulis alasannya. Jangan diabaikan diam-diam.
- Jangan menghapus atau menulis ulang file di luar cakupan tugas tanpa izin user.
