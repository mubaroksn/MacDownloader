# MacDownloader — handoff for Claude

Status per 17 Okt 2026. Pemilik: mubaroksn (berkomunikasi dalam bahasa Indonesia, santai; bukan engineer Swift — jelaskan hasil, bukan proses).

## Apa ini
Download manager ala IDM untuk macOS. Native Swift/SwiftUI, SwiftPM (tanpa .xcodeproj), macOS 13+, universal.
Repo: https://github.com/mubaroksn/MacDownloader · Rilis terbaru: **v1.3.0**.
Detail arsitektur: `ARCHITECTURE.md`. Ringkasan pengguna: `README.md`.

## Yang sudah ada
- `Sources/DownloadCore` (engine tanpa UI): probe Range, TaskGroup workers, work-stealing scheduler,
  1 URLSession per range request (koneksi TCP terpisah), pwrite + F_PREALLOCATE, If-Range,
  shed koneksi saat 429/503, **auto-scale koneksi** (8 awal → maks 32, lepas lagi kalau tidak menambah speed),
  `LinkResolver` (Drive/Docs/Dropbox/GitHub/SharePoint/Pixeldrain + halaman virus-scan Drive, MediaFire),
  `DriveFolder` (folder Drive publik via `window['_DRIVE_ivd']`, diverifikasi Okt 2026; `embeddedfolderview` sudah mati).
- `Sources/MacDownloader`: UI monokrom (rail, sidebar tree, kartu folder, tabel), menu bar, IOKit sleep assertion,
  clipboard monitor, ekstensi Chromium (pause → hand-off → resume kalau app menolak; heartbeat 30 dtk).
- `Sources/mdl-bench`: CLI benchmark throughput/CPU. `Tests/DownloadCoreTests`: 39 tes (server range lokal).

## Cara kerja dari sesi Claude (penting)
- Workspace Claude = Linux, **tidak bisa compile Swift**. Semua build/tes lewat GitHub Actions (macos-14).
- Log Actions & artifact **tidak bisa diunduh** dari proxy. Workflow sengaja menulis hasil sebagai **annotations**
  (`gh api repos/mubaroksn/MacDownloader/check-runs/<job>/annotations`) — error compiler, hasil tes, smoke test.
- Screenshot UI: step CI mem-push PNG ke branch `ci-screenshots` → `git fetch origin ci-screenshots`.
- Rilis: `gh api -X POST repos/mubaroksn/MacDownloader/actions/workflows/build.yml/dispatches -f ref=main -f 'inputs[release]=X.Y.Z'`
  (push tag diblokir proxy). PR/merge lewat REST (`gh api .../pulls`), GraphQL diblokir. Hapus branch tidak bisa.
- Alur biasa: branch → PR → CI hijau (tes + smoke + screenshot) → squash merge → dispatch rilis.
- Benchmark: push ke branch `perf-*` menjalankan `.github/workflows/bench.yml`.

## Konteks pengguna
- Browser: **Dia** (Chromium). Ekstensi sudah aktif dan bekerja. Internet: **Starlink ~200 Mbps**.
- Keluhan terakhir: ZIP folder Google Drive (`takeout-download…`) hanya ~4,3 MB/s (≈1 koneksi Starlink).
  Benchmark: engine sanggup 570–920 Mbps ke Google Drive di datacenter → batasnya server/jaringan, bukan engine.

## Terbuka / langkah berikutnya
1. Tunggu hasil tes pengguna di v1.3.0: apakah baris ZIP Drive menampilkan "1 koneksi · server tidak mendukung
   multi-koneksi", dan berapa speed saat menempel **link folder** (unduhan paralel per file).
2. Nama app: pengguna ingin tetap ada kata "warp", condong ke **"wwwarp"** — belum diputuskan/diterapkan.
3. Kandidat fitur: Native Messaging host (Chromium), Safari Web Extension (butuh migrasi ke Xcode project),
   video grabber (yt-dlp) — belum diminta.
4. Branch sisa yang bisa dihapus pemilik: `probe-drive`, `perf-speed`, `engine-v2`, `drive-folders`.
