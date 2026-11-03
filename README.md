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
  2. Di laptop Ashira (repo app): `php artisan license:buat <ID> --untuk="PT ..." --sampai=2027-12-31`.
  3. Kirim `storage\app\license.lic` hasilnya; unggah di halaman `/aktivasi`.

## Yang dipasang

**Komputer master** (`C:\VerifikasiFaktur\`):

| Folder | Isi |
|---|---|
| `app\` | Aplikasi (diganti tiap update; `app\storage` = junction ke `data\storage`) |
| `php\`, `apache\` | PHP 8.3 & Apache 2.4 |
| `data\` | `database.sqlite`, `storage\` (PDF faktur, lisensi, log), `.env`, `install.log` |
| `backup\` | Backup per jam / harian / manual / sebelum-pulihkan / sebelum-update |
| `INFO-PEMASANGAN.txt` | Alamat untuk komputer scan + kode pemasangan |

Layanan Windows `VerifikasiFaktur` (Apache, otomatis saat nyala, restart sendiri bila mati), aturan
firewall "Verifikasi Faktur" (profil Private, port 80 atau 8080), tugas `\VerifikasiFaktur\Jadwal` tiap
menit (akun SYSTEM, tetap jalan saat pakai baterai), ikon "Verifikasi Faktur" dan "Reset superadmin".

**Komputer scan**: ikon "Verifikasi Faktur" (Edge mode aplikasi ke alamat master), tugas
`\VerifikasiFaktur\TarikBackup` tiap jam → `C:\VerifikasiFaktur\backup\` (24 per jam + 7 harian).

Copot (Settings → Apps): layanan, tugas, firewall, ikon dihapus; `data\` dan `backup\` **dibiarkan**.

## Pemasangan senyap (uji / otomatis)

```powershell
Verifikasi-Faktur-Setup-1.0.0.exe /VERYSILENT /ROLE=master /SKIPADMIN=1
Verifikasi-Faktur-Setup-1.0.0.exe /VERYSILENT /ROLE=scan /SERVER=192.168.1.10 /CODE=ABCD2345
```
