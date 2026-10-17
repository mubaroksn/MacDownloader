# MacDownloader

Download manager untuk macOS ala IDM: native SwiftUI, universal (Apple Silicon + Intel), macOS 13 ke atas. Tampilan monokrom dengan mode terang dan gelap yang mengikuti setelan Mac.

![MacDownloader, mode terang](docs/screenshot-light.png)

![MacDownloader, mode gelap](docs/screenshot-dark.png)

## Fitur

- **Download multi-koneksi.** File dipecah menjadi segmen yang diunduh paralel (default 8 koneksi, maksimal 32), masing-masing di koneksi TCP terpisah. Koneksi yang selesai lebih dulu mengambil alih setengah sisa segmen terbesar (work stealing), sehingga ujung download tidak tertahan oleh satu koneksi lambat.
- **Langsung ke disk.** Data ditulis ke posisinya di satu file (`pwrite`) yang ruangnya sudah dipesan di awal. Tidak ada file part dan tidak ada proses penggabungan. Kalau disk tidak cukup, download langsung ditolak di awal.
- **Pause/resume yang aman.** Progres tersimpan dan bisa dilanjutkan setelah restart. File di server divalidasi dengan `If-Range` (ETag/Last-Modified): kalau file di server berubah, download diulang, bukan disambung.
- **Tahan server yang membatasi.** Saat server menolak (429/503) atau koneksi gagal, jumlah koneksi dikurangi, lalu dinaikkan lagi bertahap saat server pulih.
- **Hemat baterai.** Mac dicegah tidur hanya selama ada download aktif (layar tetap boleh mati), dan pembaruan tampilan hanya berjalan saat ada transfer.
- **Ikon menu bar** untuk melihat progres, menjeda, atau melanjutkan download dengan cepat.
- **Antrian & kategori.** Ada batas download bersamaan, dan file otomatis masuk ke subfolder Video, Musik, Dokumen, Program, Arsip, Gambar, atau Lainnya.
- **Integrasi browser** untuk Chrome, Edge, Brave, dan Arc: download diambil alih otomatis dan tersedia menu klik kanan. Cookie dan referrer ikut dikirim.

Detail teknis ada di [ARCHITECTURE.md](ARCHITECTURE.md).

## Instalasi

1. Unduh `MacDownloader-x.y.z.dmg` dari tab **Actions** (artifact build terbaru) atau dari **Releases**.
2. Buka DMG, lalu tarik **MacDownloader** ke **Applications**.
3. Pembukaan pertama: app ini belum ditandatangani dengan Apple Developer ID, jadi macOS akan memblokirnya. Klik kanan **MacDownloader** di Applications, pilih **Open**, lalu klik **Open** lagi. Jika masih diblokir, buka **System Settings → Privacy & Security** dan klik **Open Anyway**.

## Memasang ekstensi browser

1. Di app, buka **MacDownloader → Settings → Browser**, lalu klik **Siapkan ekstensi**.
2. Di browser, buka `chrome://extensions` (Edge: `edge://extensions`) dan aktifkan **Developer mode**.
3. Klik **Load unpacked**, lalu pilih folder `ChromeExtension` yang terbuka di Finder.

App berkomunikasi dengan ekstensi melalui `127.0.0.1:9614` dan hanya bisa diakses dari Mac itu sendiri.

## Membuat rilis

Buka tab **Actions → Build macOS app → Run workflow**, isi kolom versi (misalnya `1.0.1`), lalu jalankan. Atau push tag `v1.0.1`. GitHub Actions akan membuat Release berisi DMG dan zip ekstensi.

Setiap build juga menjalankan smoke test di Mac: aplikasi dibuka, lalu dites mengunduh file 10 MB lewat jalur ekstensi browser, dan hasilnya dicocokkan byte per byte.

Build dan tes lokal di Mac (butuh Xcode Command Line Tools):

```bash
swift test             # unit + integration test engine
scripts/build_app.sh   # hasil ada di dist/
```

Untuk mengembangkan di Xcode: buka `Package.swift` langsung (File › Open). Xcode menampilkan target `MacDownloader`, `DownloadCore`, dan `DownloadCoreTests`.

## Struktur

| File | Isi |
|---|---|
| `Sources/DownloadCore/` | Engine tanpa UI: probe, segmentasi, transfer paralel, penulisan disk |
| `Sources/MacDownloader/Downloads/` | Antrian, penyimpanan progres, notifikasi |
| `Sources/MacDownloader/Ingest/` | Pintu masuk download (ekstensi browser, dll.) |
| `Sources/MacDownloader/System/` | Manajemen daya (IOKit, App Nap) |
| `Sources/MacDownloader/UI/` | Tampilan SwiftUI dan menu bar |
| `Tests/DownloadCoreTests/` | Unit test dan tes end-to-end dengan server lokal |
| `ChromeExtension/` | Ekstensi Chromium (Manifest V3) |
