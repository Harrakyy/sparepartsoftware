# sparepartsoftware — installer Verifikasi Faktur (edisi offline)

Membungkus app [`sparepartscan`](https://github.com/Harrakyy/sparepartscan) + PHP + Apache menjadi satu
`Verifikasi-Faktur-Setup-<versi>.exe`. Setup memasang **komputer master** (server + data) atau **komputer
scan** (ikon + salinan backup per jam), tanpa internet di lokasi.

## Build

Prasyarat di laptop build (Windows 10/11):

- Git, Composer, PHP ≥ 8.3.36 di PATH dengan **ekstensi `zip` aktif** (tanpa itu composer meng-clone paket
  lewat git dan gagal di Windows).
- Inno Setup 6: `winget install JRSoftware.InnoSetup`.
- Repo app di `..\sparepart` (atau `-AppRepo <path>`).

```powershell
.\build.ps1 -AppRef HEAD     # build uji dari commit terakhir app
.\build.ps1                  # rilis: app dari tag v<AppVersion> (versions.psd1)
.\build.ps1 -SkipInno        # hanya siapkan stage\
```

Hasil: `dist\Verifikasi-Faktur-Setup-<versi>.exe` + `dist\RELEASE-NOTES.txt` (versi app/PHP/Apache + SHA-256).

Build **menolak** bila: checksum unduhan beda dari `versions.psd1`, PHP di paket < `MinPhp`, `composer audit`
menemukan celah, atau `secret.key` / `license.lic` ikut masuk paket.

Tes: `Invoke-Pester .\tests` (Pester bawaan Windows PowerShell 5.1).

## Rilis

1. Di repo app: semua tes hijau, `composer audit` bersih, lalu `git tag v<versi>`.
2. Ubah `AppVersion` di `versions.psd1`, jalankan `.\build.ps1`.
3. Simpan `Setup.exe` + `RELEASE-NOTES.txt`. Update di komputer master cukup menjalankan Setup versi baru
   (data, `.env`, lisensi tetap; backup `sebelum-update` dibuat otomatis).

**Memperbarui versi PHP/Apache/VC++:** ganti URL + SHA-256 di `versions.psd1` dari sumber resmi
(`windows.php.net/downloads/releases/sha256sum.txt`, file `.txt` di Apache Lounge, tanda tangan Microsoft
pada `vc_redist.x64.exe`).

## Lisensi (penguncian komputer)

- Kunci rahasia `storage\app\keys\secret.key` ada **hanya** di laptop Ashira (repo app, tidak di-commit).
  **Backup file ini ke tempat aman** (flashdisk pribadi / password manager). Hilang = tidak bisa membuat
  lisensi baru untuk komputer yang sudah terpasang.
- Membuat lisensi untuk komputer master pelanggan:
  1. Setelah Setup, halaman `/aktivasi` di komputer master menampilkan **ID komputer**.
  2. Di laptop Ashira, klik dua kali **`sparepart\tools\Buat Lisensi.bat`** → isi ID + "Untuk" → file
     `lisensi <untuk>.lic` terunduh (berlaku selamanya; riwayat di `storage\app\keys\riwayat-lisensi.csv`).
     Cadangan lewat perintah: `php artisan license:buat <ID> --untuk="PT ..."`.
  3. Unggah file itu di halaman `/aktivasi` → halaman **Buat akun superadmin** muncul.

## Alur di lokasi (kabel LAN lewat switch)

1. **Master**: colok kabel ke switch → Setup → *Komputer master* → halaman **Pemeriksaan komputer**
   (Smart App Control, 64-bit, disk, port LAN tidak dipakai jaringan kantor, bentrok alamat) →
   centang *kabel* & *jangan tidurkan* → Pasang → aktivasi lisensi → buat akun superadmin.
2. **Scan 1 / Scan 2**: colok kabel ke switch → Setup → *Komputer scan* → pemeriksaan → pilih
   **Titik scan 1/2** → ketik **kode pemasangan** (ikon *Info pemasangan* di master) → Pasang.
3. Petugas klik **Daftar** di halaman masuk (bisa dimatikan superadmin di menu Pengguna).
4. Uji: dua titik scan barang yang sama bersamaan; restart master → kedua titik tersambung lagi.

Alamat kabel tetap: master `192.168.77.1`, titik 1 `.2`, titik 2 `.3` (tanpa gateway; WiFi tidak
terganggu). Firewall "Verifikasi Faktur (kabel)" hanya menerima dari `192.168.77.x`, di semua profil.

Uji beban sebelum rilis (butuh `stage\`): `tests\load\Jalankan-Server-Uji.ps1` lalu
`tests\load\Uji-Beban.ps1 -BaseUrl http://127.0.0.1:8099 -Username bos -Password rahasia123`
(lulus = hitungan tepat, tanpa galat), lalu `Jalankan-Server-Uji.ps1 -Stop`.

## Yang dipasang

**Komputer master** (`C:\VerifikasiFaktur\`):

| Folder | Isi |
|---|---|
| `app\` | Aplikasi (diganti tiap update; `app\storage` = junction ke `data\storage`) |
| `php\`, `apache\` | PHP 8.3 & Apache 2.4 |
| `data\` | `database.sqlite`, `storage\` (PDF faktur, lisensi, log), `.env`, `install.log`, `cable.json`, `power.json` |
| `backup\` | Backup per jam / harian / manual / sebelum-pulihkan / sebelum-update |
| `INFO-PEMASANGAN.txt` | Alamat untuk komputer scan + kode pemasangan |

Layanan Windows `VerifikasiFaktur` (Apache, otomatis saat nyala, restart sendiri bila mati), aturan
firewall "Verifikasi Faktur" (Private) dan "Verifikasi Faktur (kabel)", tugas `\VerifikasiFaktur\Jadwal`
tiap menit (akun SYSTEM, tetap jalan saat pakai baterai), ikon "Verifikasi Faktur", "Info pemasangan",
dan "Reset superadmin".

**Komputer scan**: port LAN `192.168.77.2/.3`, ikon "Verifikasi Faktur" (Edge mode aplikasi ke master),
tugas `\VerifikasiFaktur\TarikBackup` tiap jam → `C:\VerifikasiFaktur\backup\` (24 per jam + 7 harian).

Copot (Settings → Apps): layanan, tugas, firewall, ikon dihapus; port LAN & setelan daya dikembalikan
seperti semula; `data\` dan `backup\` **dibiarkan**.

## Pemasangan senyap (uji / otomatis)

```powershell
Verifikasi-Faktur-Setup-1.0.0.exe /VERYSILENT /ROLE=master /CABLE=1 /PORT=8080
Verifikasi-Faktur-Setup-1.0.0.exe /VERYSILENT /ROLE=scan /CABLE=1 /POINT=1 /CODE=ABCD2345
Verifikasi-Faktur-Setup-1.0.0.exe /VERYSILENT /ROLE=scan /CABLE=0 /SERVER=192.168.1.10 /CODE=ABCD2345
```
