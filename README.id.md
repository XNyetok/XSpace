# XSpace

**Banyak profil browser yang terisolasi dalam satu jendela macOS. Native, ringan, privat.**

XSpace menaruh beberapa "browser" berdampingan dalam satu jendela. Setiap profil punya cookie,
login, dan data situs sendiri yang terpisah total dari profil lain. Contoh pemakaian: Google
AI Studio di samping Google Sheets untuk beberapa akun Google sekaligus, tanpa akun saling
bercampur dan tanpa banyak jendela browser yang tersebar di beberapa Space.

> **Status:** prototype awal (0.x). macOS 26+.
>
> 🇬🇧 English: [README.md](README.md)

## Kenapa XSpace

- **Satu jendela**, bukan beberapa jendela browser penuh.
- **Profil benar-benar terpisah.** Setiap profil adalah data store WebKit persisten sendiri,
  bukan sekadar grup tab.
- **Hemat memori.** Swift + AppKit native di atas WebKit bawaan sistem: tanpa Electron, tanpa
  Chromium. Di Mac Apple M2 dengan RAM 8 GB, dua halaman yang sama (AI Studio + Sheets, belum
  login) memakai sekitar **536 MB** di XSpace dibanding **964 MB** di Chrome dengan profil baru
  tanpa ekstensi (physical footprint, diukur dengan build tanpa sandbox).

## Fitur

- Profil dengan data situs terisolasi penuh (satu `WKWebsiteDataStore(forIdentifier:)` per profil)
- Pane berdampingan dalam satu profil (default: Google AI Studio | Google Sheets), bisa diubah
  lebarnya dan ditukar posisinya
- Mode **Fokus** (satu profil) dan **Semua** (semua profil ditumpuk sebagai grid)
- Warna per profil dan bingkai pane, supaya selalu jelas sedang di akun mana
- Popup dan jendela login tetap di dalam profilnya
- Hemat RAM: lazy load, pembekuan otomatis profil tersembunyi, indikator RAM
- Unduhan, upload file, izin kamera/mikrofon, zoom halaman, back/forward
- App Sandbox + Hardened Runtime, tanpa telemetri, tanpa dependensi pihak ketiga

## Kebutuhan

- macOS 26 Tahoe atau lebih baru. Untuk macOS 14 dan 15, pakai
  [XSpace 0.4.0](https://github.com/XNyetok/XSpace/releases/tag/v0.4.0), versi terakhir yang
  mendukungnya.
- Untuk build: Xcode 26+ (atau Command Line Tools-nya)

## Instal

Unduh `XSpace-<versi>.zip` dari [Releases](https://github.com/XNyetok/XSpace/releases), ekstrak,
lalu pindahkan **XSpace.app** ke folder Applications. Build rilis jalan di Mac Apple silicon
maupun Intel.

Rilis belum dinotarisasi Apple (butuh Developer ID berbayar), jadi macOS memblokir pembukaan
pertama: buka XSpace, klik **Selesai** di peringatan, lalu buka **Pengaturan Sistem → Privasi &
Keamanan** dan klik **Tetap Buka** di pesan tentang XSpace.

Build rilis ditandatangani ad-hoc, jadi setelah update macOS bisa bertanya apakah XSpace boleh
mengakses datanya: pilih **Izinkan**, kalau tidak profil kamu tidak akan muncul. Build sendiri
dengan sertifikat Apple Development gratis (lihat di bawah) menghindari kedua pertanyaan itu.

## Build dari source

```bash
git clone https://github.com/XNyetok/XSpace.git
cd XSpace
./scripts/build.sh               # hasil: build/XSpace.app untuk Mac ini
open build/XSpace.app
./scripts/build.sh --install     # opsional: salin juga ke ~/Applications
./scripts/build.sh --universal   # opsional: Apple silicon + Intel (dipakai untuk rilis)
```

**Tanda tangan kode.** `build.sh` memakai identitas *Apple Development* atau *Developer ID
Application* pertama yang valid di keychain, atau yang disebut di `XSPACE_SIGN_IDENTITY` (`-`
memaksa ad-hoc). Tanpa identitas, app ditandatangani ad-hoc: tetap jalan, tapi karena tanda
tangan app ber-sandbox berubah tiap build, macOS bisa meminta konfirmasi setelah build ulang.
Sertifikat Apple Development gratis (Xcode → Settings → Accounts → Manage Certificates)
menghindari hal itu. Tanda tangan Developer ID juga diberi timestamp aman yang diwajibkan untuk
notarisasi.

## Cara pakai

| Aksi | Cara |
|---|---|
| Pindah profil | klik di toolbar, atau ⌘1–⌘9 |
| Tambah profil | tombol **+** atau ⇧⌘N |
| Ganti nama/warna, reset pane, hapus profil | tombol **⋯** atau menu **Profil** |
| Satu profil / semua profil sekaligus | **Fokus / Semua** di kanan atas, atau ⌃⌘G |
| Kolom alamat pane aktif | ⌘L |
| Muat ulang / kembali / maju | ⌘R / ⌘[ / ⌘] |
| Zoom pane | ⌘= / ⌘- / ⌘0 |
| Ubah lebar pane | geser pembatas; klik dua kali = rata lagi |
| Tukar posisi dua pane | tombol ⇄ di antara pane, ⌃⌘X, atau menu **Profil → Tukar Posisi Pane** |
| Pemakaian & pengaturan hemat RAM | indikator **RAM …**, atau menu **Tampilan → Hemat RAM** |

### Hemat RAM

Profil yang belum pernah dibuka tidak dimuat sama sekali. Profil yang tidak terlihat tidak
dirender dan di-throttle WebKit, dan bisa **dibekukan**: webview-nya dihancurkan sehingga
memorinya kembali ke sistem, lalu halaman dimuat ulang saat profil dibuka lagi. Kamu tetap
login, tapi isian di halaman yang belum tersimpan bisa hilang. Atur kapan ini terjadi lewat
menu indikator RAM:

- **Setelah 15 menit tidak dilihat** (default, plus saat RAM menipis)
- **Langsung saat disembunyikan** (paling hemat)
- **Hanya saat RAM menipis** (saat macOS melaporkan memori menipis)
- **Jangan pernah**

Profil yang sedang tampil tidak pernah dibekukan otomatis. Di dalam sandbox, macOS hanya
mengizinkan app membaca *resident size* proses pembantu WebKit, jadi indikator menampilkan total
perkiraan (≈) yang biasanya sedikit lebih tinggi daripada Activity Monitor.

### Login Google

Login dengan password (plus verifikasi 2 langkah) berjalan, dan Google tidak memblokir dengan
pesan "browser atau aplikasi ini mungkin tidak aman" karena XSpace memakai User-Agent Safari.
**Passkey tidak bisa dipakai**: WebAuthn di app WKWebView pihak ketiga butuh entitlement browser
dari Apple. Kalau Google menawarkan passkey, pilih **Coba cara lain**. Login cukup sekali per
profil; sesinya tersimpan.

## Privasi & keamanan

- Berjalan di **App Sandbox** dengan **Hardened Runtime**. Izin: jaringan keluar, file pilihan
  pengguna, folder Downloads, kamera, mikrofon (lihat `Support/XSpace.entitlements`).
- Semua data tetap di Mac, di dalam container app:
  `~/Library/Containers/io.github.xnyetok.xspace/`.
- Saat profil dihapus, seluruh data situsnya (cookie, penyimpanan, cache) ikut terhapus dari Mac
  begitu WebKit melepasnya, paling lambat saat XSpace dibuka lagi.
- Tanpa telemetri, analitik, atau crash reporting. Tidak ada request jaringan selain halaman yang
  kamu buka.
- Tidak ada JavaScript yang disuntikkan ke halaman.
- Dua API privat WebKit (SPI) dipakai, keduanya selalu dicek dulu sehingga perubahan macOS di
  masa depan tidak membuat app crash: membaca PID proses WebKit untuk indikator RAM, dan menulis
  cookie ke disk saat app ditutup (panggilan yang sama dengan Safari), sebagai pengaman untuk
  sesi yang baru dibuat sesaat sebelum app ditutup.
- Laporkan celah keamanan secara privat; lihat [SECURITY.md](SECURITY.md).

## Pengembangan

```bash
swift test                 # unit test: kolom alamat, state tersimpan, pembagi pane, unduhan, ...
APP=build/XSpace.app/Contents/MacOS/XSpace
$APP --selftest            # isolasi profil, halaman Google, User-Agent, persistensi (tulis)
$APP --selftest-persist    # persistensi (baca ulang) + bersih-bersih
$APP --selftest-ui         # jendela sungguhan dengan state sementara: pembekuan, tukar pane,
                           # hapus profil, indikator RAM
```

Semua self-test memakai profil uji sementara dan tidak menyentuh profil asli. Set
`XSPACE_SELFTEST_OFFLINE=1` untuk melewati bagian yang butuh internet. CI menjalankan semuanya
(offline) di macOS 26 dan menganggap warning compiler sebagai error;
`XSPACE_WARNINGS_AS_ERRORS=1 ./scripts/build.sh` melakukan hal yang sama di lokal.

| File | Isi |
|---|---|
| `Sources/XSpace/Models.swift` | state yang disimpan; satu profil = satu `WKWebsiteDataStore` |
| `Sources/XSpace/WebKitSupport.swift` | konfigurasi webview, User-Agent Safari, penghapusan data store, unduhan, halaman error |
| `Sources/XSpace/PaneView.swift` | satu pane: toolbar mini + `WKWebView` + delegate navigasi/UI |
| `Sources/XSpace/ProfileRowView.swift` | baris profil, pembagi pane, container grid |
| `Sources/XSpace/MainWindowController.swift` | jendela utama, toolbar, aksi profil, hemat RAM |
| `Sources/XSpace/MemoryMonitor.swift` | pengukuran memori dan pemantau tekanan memori macOS |
| `Sources/XSpace/PopupWindowController.swift` | popup yang tetap di profilnya |
| `Sources/XSpace/AppDelegate.swift` | menu dan siklus hidup app |
| `Sources/XSpace/SelfTest.swift`, `UISelfTest.swift` | self-test |
| `Tests/XSpaceTests/` | unit test (`swift test`) |
| `scripts/build.sh` | build dan tanda tangan `build/XSpace.app` |
| `scripts/make-icon.swift` | menggambar ikon app (`Support/AppIcon.icns`) |

Panduan kontribusi: [CONTRIBUTING.md](CONTRIBUTING.md). Issue dan PR boleh dalam Bahasa
Indonesia atau Inggris.

## Rencana

- UI bahasa Inggris dan lokalisasi yang rapi (Indonesia + Inggris)
- Layout fleksibel: jumlah pane per profil, preset per workspace
- Rilis yang ditandatangani Developer ID dan dinotarisasi (saat ini rilis masih ad-hoc)
- Proxy per profil (opsional)
- Notifikasi web diteruskan ke notifikasi macOS

## Lisensi

[MIT](LICENSE). Tidak berafiliasi dengan Google atau Apple. Google AI Studio dan Google Sheets
adalah merek dagang Google LLC.
