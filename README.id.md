# XSpace

**Banyak profil browser yang terisolasi dalam satu jendela macOS. Native, ringan, privat.**

XSpace menaruh beberapa "browser" berdampingan dalam satu jendela: setiap profil adalah satu pane
dengan cookie, login, dan data situs sendiri yang terpisah total dari profil lain. Contoh
pemakaian: Google AI Studio untuk beberapa akun Google sekaligus dalam satu grid, tanpa akun
saling bercampur dan tanpa banyak jendela browser yang tersebar di beberapa Space.

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
- Satu pane per profil, diatur dengan tata letak: **Otomatis** (semua profil dalam grid), 1,
  2 berdampingan, 2 bertumpuk, 3 berdampingan, 2 × 2, 1 + 2, atau 1 + 3. Ukuran pane bisa
  diubah dan posisinya ditukar, dan setiap tata letak mengingat profil dan ukurannya
- Zoom otomatis: pane yang kecil menampilkan halamannya lebih kecil (paling kecil 70%), jadi situs
  tetap memakai tampilan seperti di jendela browser, bukan tampilan untuk ponsel
- Layar sambutan untuk memilih tata letak saat pertama dibuka, dan halaman awal seperti tab baru
  di browser, dengan pintasan ke situs-situsmu: tidak ada yang dimuat sebelum kamu membuka halaman
- Warna per profil dan bingkai pane, supaya selalu jelas sedang di akun mana
- Popup login tetap di dalam profilnya. Belum ada tab: tautan yang membuka tab baru menampilkan
  catatan singkat di panenya
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
| Mulai | saat pertama dibuka, pilih tata letak di layar sambutan: XSpace membuat satu profil untuk setiap panenya |
| Buka halaman di profil baru | ketik alamat atau kata kunci di kotak pencarian halaman awalnya (atau di kolom alamatnya), lalu tekan Return |
| Halaman awal | tombol rumah di toolbar pane, atau ⇧⌘H; ⌘[ kembali ke halamannya |
| Pintasan di halaman awal | **Tambah pintasan** menambah satu, ke profil itu atau sekaligus ke semua profil; klik kanan pintasan, atau tombol ⋯-nya, untuk mengubah atau menghapusnya |
| Pilih tata letak | tombol **Tata Letak** di toolbar, atau menu **Tampilan → Tata Letak** |
| Tampilkan profil | klik di toolbar (yang sedang tampil disorot), atau ⌘1–⌘9: profil yang tersembunyi menggantikan pane yang aktif |
| Pilih profil sebuah pane | klik nama profil di kiri toolbar pane (profil yang tampil di tempat lain bertukar posisi) |
| Hanya profil yang aktif, lalu kembali | ⌃⌘G (**Tampilan → Tampilkan Satu Profil**) |
| Tukar posisi dua pane | tombol ⇄ di antara dua pane yang berdampingan, atau ⌃⌘X untuk pane aktif dan pane berikutnya |
| Tambah profil | tombol **+** atau ⇧⌘N: mengisi slot kosong, atau pane yang aktif |
| Ganti nama/warna atau hapus profil | tombol **⋯** atau menu **Profil**; menghapus profil terakhir memunculkan layar sambutan lagi |
| Kolom alamat pane aktif | ⌘L |
| Muat ulang / kembali / maju | ⌘R / ⌘[ / ⌘] |
| Tautan yang membuka tab baru | belum didukung: pane menampilkan catatan singkat di bagian bawahnya. Jendela popup yang punya ukuran sendiri, seperti jendela login, tetap terbuka |
| Zoom pane | otomatis (lihat [Zoom](#zoom)); **+** / **−** di kanan toolbar pane, atau ⌘= / ⌘- di pane yang aktif, memperbesar atau memperkecil pane itu dari situ; klik angka zoom-nya, atau tekan ⌘0, untuk kembali ke zoom otomatis |
| Ubah ukuran pane | geser pembatas; klik dua kali = rata lagi; ⌃⌘0 (**Tampilan → Atur Ulang Ukuran Pane**, juga di bagian bawah menu **Tata Letak**) mengembalikan pane di tata letak itu ke ukuran bawaannya |
| Pemakaian & pengaturan hemat RAM | indikator **RAM …**, atau menu **Tampilan → Hemat RAM** |

Profil yang aktif adalah yang panenya sedang menerima ketikan; perintah profil berlaku untuknya.

### Zoom

Situs web dibuat untuk jendela browser. Pane yang lebih kecil dari jendela browser yang kecil
(1024 × 640 poin) menampilkan halamannya lebih kecil, turun per 5% sampai paling kecil 70%, jadi
halaman tetap disusun seperti di jendela browser, bukan berpindah ke tampilan untuk tablet atau
ponsel. Di MacBook Air 13 inci, satu profil tetap 100% dan pane di tata letak lain 70%. Selama
pembatas atau jendela sedang digeser, zoom menunggu sampai tombol mouse dilepas.

Setiap pane menampilkan zoom-nya di kanan toolbar. **+** dan **−** di sebelahnya (atau ⌘= dan ⌘-
di pane yang aktif) memperbesar atau memperkecil halaman itu dari zoom otomatis, per 10%: angka
zoom-nya lalu berwarna aksen, dan profilnya mengingat ini, juga setelah dibekukan dan setelah
XSpace ditutup. Klik angka zoom itu, atau tekan ⌘0 (**Tampilan → Atur Ulang Zoom**), untuk kembali
ke zoom otomatis. Pane yang lebih sempit dari 320 poin tidak menampilkan tombol-tombol ini di
toolbarnya. Untuk menampilkan semua halaman 100%, matikan **Tampilan → Zoom Otomatis**.

Zoom yang lebih kecil tidak menghemat CPU: halaman di pane kecil memakai CPU kurang lebih sama
dengan di pane besar. Yang menghemat CPU dan RAM adalah profil yang tidak tampil (lihat di bawah).

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
swift test                 # unit test: kolom alamat, state tersimpan, tata letak, zoom, pembagi pane, ...
APP=build/XSpace.app/Contents/MacOS/XSpace
$APP --selftest            # isolasi profil, halaman Google, User-Agent, persistensi (tulis)
$APP --selftest-persist    # persistensi (baca ulang) + bersih-bersih
$APP --selftest-ui         # jendela sungguhan dengan state sementara: upgrade dari 0.5.0,
                           # pembekuan, tata letak dan zoom, menampilkan dan menukar profil,
                           # fokus keyboard, indikator RAM, tab baru dan popup, hapus profil,
                           # pertama dibuka (layar sambutan, halaman awal, pintasan)
```

Semua self-test memakai profil uji sementara dan tidak menyentuh profil asli. Set
`XSPACE_SELFTEST_OFFLINE=1` untuk melewati bagian yang butuh internet. CI menjalankan semuanya
(offline) di macOS 26 dan menganggap warning compiler sebagai error;
`XSPACE_WARNINGS_AS_ERRORS=1 ./scripts/build.sh` melakukan hal yang sama di lokal.

| File | Isi |
|---|---|
| `Sources/XSpace/Models.swift` | state yang disimpan (halaman tiap profil, tata letak); satu profil = satu `WKWebsiteDataStore` |
| `Sources/XSpace/Grid.swift` | tata letak: preset sebagai pohon slot, grid otomatis |
| `Sources/XSpace/WebKitSupport.swift` | konfigurasi webview, User-Agent Safari, penghapusan data store, unduhan, halaman error |
| `Sources/XSpace/PaneView.swift` | satu pane: toolbar mini + `WKWebView` + delegate navigasi/UI |
| `Sources/XSpace/PageZoom.swift` | zoom halaman sebuah pane: otomatis dari ukuran pane, ditambah zoom profil itu sendiri |
| `Sources/XSpace/PaneNoteView.swift` | catatan singkat di bagian bawah pane, misalnya bahwa tab baru belum didukung |
| `Sources/XSpace/StartPageView.swift` | halaman awal pane, seperti tab baru di browser: kotak pencarian dan pintasan |
| `Sources/XSpace/WelcomeView.swift` | layar sambutan saat pertama dibuka: memilih tata letak |
| `Sources/XSpace/GridView.swift` | pane di slot tata letak, pane tersembunyi, slot kosong, ikon dan gambar tata letak |
| `Sources/XSpace/PaneSplitView.swift` | pembagi pane: berdampingan atau bertumpuk, bersarang, tombol tukar |
| `Sources/XSpace/MainWindowController.swift` | jendela utama, toolbar, profil dan tata letak, hemat RAM |
| `Sources/XSpace/MemoryMonitor.swift` | pengukuran memori dan pemantau tekanan memori macOS |
| `Sources/XSpace/PopupWindowController.swift` | jendela popup yang tetap di profilnya, dan apa yang dihitung sebagai popup (bukan tab baru) |
| `Sources/XSpace/AppDelegate.swift` | menu dan siklus hidup app |
| `Sources/XSpace/SelfTest.swift`, `UISelfTest.swift` | self-test |
| `Tests/XSpaceTests/` | unit test (`swift test`) |
| `scripts/build.sh` | build dan tanda tangan `build/XSpace.app` |
| `scripts/make-icon.swift` | menggambar ikon app (`Support/AppIcon.icns`) |

Panduan kontribusi: [CONTRIBUTING.md](CONTRIBUTING.md). Issue dan PR boleh dalam Bahasa
Indonesia atau Inggris.

## Rencana

- UI bahasa Inggris dan lokalisasi yang rapi (Indonesia + Inggris)
- Rilis yang ditandatangani Developer ID dan dinotarisasi (saat ini rilis masih ad-hoc)
- Proxy per profil (opsional)
- Notifikasi web diteruskan ke notifikasi macOS

## Lisensi

[MIT](LICENSE). Tidak berafiliasi dengan Google atau Apple. Google AI Studio dan Google Sheets
adalah merek dagang Google LLC.
