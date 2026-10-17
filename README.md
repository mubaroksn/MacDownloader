# MacDownloader

Download manager untuk macOS ala IDM: native SwiftUI, universal (Apple Silicon + Intel), macOS 13 ke atas. Tampilan monokrom dengan mode terang dan gelap yang mengikuti setelan Mac.

## Fitur

- **Download multi-koneksi.** File dipecah menjadi beberapa segmen yang diunduh paralel (default 8 koneksi, bisa sampai 32). Saat satu koneksi selesai, segmen tersisa yang paling besar dibelah lagi supaya semua koneksi tetap bekerja, seperti cara kerja IDM.
- **Pause / resume.** Progres tersimpan di disk, jadi download bisa dilanjutkan setelah app ditutup atau Mac di-restart. Untuk server yang tidak mendukung resume, download diulang dari awal.
- **Retry otomatis** saat koneksi putus. Kalau server membatasi koneksi (HTTP 429/503), jumlah koneksi dikurangi dan download tetap berjalan.
- **Antrian.** Atur berapa download yang berjalan bersamaan (default 3); sisanya menunggu giliran.
- **Kategori otomatis.** File disimpan ke subfolder Video, Musik, Dokumen, Program, Arsip, Gambar, atau Lainnya.
- **Integrasi browser** untuk Chrome, Edge, Brave, dan Arc:
  - Download dari browser otomatis diambil alih oleh app.
  - Klik kanan pada link lalu pilih **Download dengan MacDownloader**.
  - Cookie dan referrer ikut dikirim, sehingga file di situs yang perlu login tetap bisa diunduh.
  - Kalau app tidak berjalan, download kembali ditangani browser seperti biasa.
- Tarik link ke jendela app, tempel banyak link sekaligus, notifikasi saat selesai, dan badge di Dock.

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

Build lokal di Mac (butuh Xcode Command Line Tools):

```bash
scripts/build_app.sh   # hasil ada di dist/
```

## Struktur

| File | Isi |
|---|---|
| `Sources/MacDownloader/DownloadEngine.swift` | Engine segmen paralel, pembelahan dinamis, retry, penggabungan file |
| `Sources/MacDownloader/DownloadManager.swift` | Antrian, kategori, penyimpanan progres, notifikasi |
| `Sources/MacDownloader/LocalServer.swift` | Server lokal untuk ekstensi browser |
| `Sources/MacDownloader/*View.swift` | Tampilan SwiftUI |
| `ChromeExtension/` | Ekstensi Chromium (Manifest V3) |
