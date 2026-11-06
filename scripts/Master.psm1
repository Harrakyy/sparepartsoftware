# Logika murni pemasangan komputer master (dipakai setup-master.ps1 / pre-update.ps1, diuji Pester).

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')

$PairingAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'  # tanpa 0/O, 1/I/L: mudah dibaca & diketik

function Get-RandomBytes([int]$Count) {
    $bytes = New-Object byte[] $Count
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return $bytes
}

function New-PairingCode([int]$Length = 8) {
    $limit = 256 - (256 % $PairingAlphabet.Length)  # tolak byte di atas batas supaya tiap huruf sama peluangnya
    $code = ''
    while ($code.Length -lt $Length) {
        foreach ($b in (Get-RandomBytes 16)) {
            if ($b -lt $limit -and $code.Length -lt $Length) { $code += $PairingAlphabet[$b % $PairingAlphabet.Length] }
        }
    }
    return $code
}

function Get-AppPort {
    # Port lama dipakai lagi saat update; pasang baru: 80 bila bebas, selain itu 8080.
    param([int]$Previous = 0, [scriptblock]$IsListening = { param($p) [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) })

    if ($Previous -gt 0) { return $Previous }
    if (-not (& $IsListening 80)) { return 80 }
    return 8080
}

function ConvertFrom-EnvText([string]$Text) {
    $map = [ordered]@{}
    if (-not $Text) { return $map }
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*([A-Z0-9_]+)=(.*)$') { $map[$Matches[1]] = $Matches[2] }
    }
    return $map
}

function New-EnvContent {
    <#
      Isi .env edisi offline. APP_KEY dan kode pemasangan dari .env lama dipertahankan (APP_KEY baru
      membuat sesi & data terenkripsi tak terbaca; kode baru memutus komputer scan). Kunci lain yang
      ditambahkan manual (mis. nama perusahaan di struk) juga dipertahankan.
    #>
    param([string]$Existing, [Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)][string]$BackupDir, [Parameter(Mandatory)][string]$Url)

    $old = ConvertFrom-EnvText $Existing
    $key = if ($old.Contains('APP_KEY') -and $old['APP_KEY']) { $old['APP_KEY'] } else { 'base64:' + [Convert]::ToBase64String((Get-RandomBytes 32)) }
    $code = if ($old.Contains('APP_PAIRING_CODE') -and $old['APP_PAIRING_CODE']) { $old['APP_PAIRING_CODE'] } else { New-PairingCode }

    # Petik tunggal = literal di Laravel/dotenv (backslash path Windows tidak dianggap escape).
    $managed = [ordered]@{
        APP_NAME          = '"Verifikasi Faktur"'
        APP_ENV           = 'production'
        APP_KEY           = $key
        APP_DEBUG         = 'false'
        APP_URL           = $Url
        APP_EDITION       = 'offline'
        APP_PAIRING_CODE  = $code
        LOG_CHANNEL       = 'daily'
        LOG_LEVEL         = 'warning'
        DB_CONNECTION     = 'sqlite'
        DB_DATABASE       = "'" + (Join-Path $DataDir 'database.sqlite') + "'"
        BACKUP_DIR        = "'$BackupDir'"
        SESSION_DRIVER    = 'file'
        CACHE_STORE       = 'file'
        QUEUE_CONNECTION  = 'sync'
    }

    $lines = foreach ($k in $managed.Keys) { "$k=$($managed[$k])" }
    $extra = foreach ($k in $old.Keys) { if (-not $managed.Contains($k)) { "$k=$($old[$k])" } }
    return (@($lines) + @($extra)) -join "`n"
}

function Test-Junction([string]$Path) {
    return (Test-Path $Path) -and (((Get-Item $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Set-StorageLink {
    <#
      data\storage menyimpan PDF faktur, lisensi, log, dan sesi — di luar app\ supaya update aman.
      Salin isi template yang belum ada (tanpa menimpa data), selalu perbarui public.key dari versi app,
      lalu jadikan app\storage junction ke data\storage.
    #>
    param([Parameter(Mandatory)][string]$AppDir, [Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)][string]$TemplateDir)

    $storage = Join-Path $DataDir 'storage'
    $tpl = (Resolve-Path $TemplateDir).Path.TrimEnd('\')
    foreach ($item in (Get-ChildItem $tpl -Recurse -Force)) {
        $target = Join-Path $storage $item.FullName.Substring($tpl.Length).TrimStart('\')
        if ($item.PSIsContainer) {
            New-Item -ItemType Directory -Force $target | Out-Null
        } elseif (-not (Test-Path $target)) {
            New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
            Copy-Item $item.FullName $target
        }
    }
    $publicKey = Join-Path $tpl 'app\keys\public.key'
    if (Test-Path $publicKey) {
        New-Item -ItemType Directory -Force (Join-Path $storage 'app\keys') | Out-Null
        Copy-Item $publicKey (Join-Path $storage 'app\keys\public.key') -Force
    }

    $link = Join-Path $AppDir 'storage'
    if (Test-Path $link) {
        if (-not (Test-Junction $link)) { throw "$link adalah folder biasa, bukan junction; dihentikan supaya data tidak tertimpa." }
        cmd /c rmdir "$link" | Out-Null
    }
    cmd /c mklink /J "$link" "$storage" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Gagal membuat junction $link -> $storage" }
}

function Remove-AppDir {
    # Hapus app\ untuk update/copot. Junction app\storage dilepas dulu (rmdir tidak menelusuri isinya),
    # sehingga data\storage (PDF faktur, lisensi) tidak ikut terhapus.
    param([Parameter(Mandatory)][string]$AppDir)

    if (-not (Test-Path $AppDir)) { return }
    $link = Join-Path $AppDir 'storage'
    if (Test-Path $link) {
        if (-not (Test-Junction $link)) { throw "$link bukan junction; app\ tidak dihapus supaya data tidak hilang." }
        cmd /c rmdir "$link" | Out-Null
        if (Test-Path $link) { throw "Gagal melepas junction $link; app\ tidak dihapus." }
    }
    Remove-Item $AppDir -Recurse -Force
}

function Get-InstallInfo {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$PairingCode,
        [string]$NetworkCategory = 'Private',
        [bool]$Dhcp = $false
    )

    $lines = @(
        'VERIFIKASI FAKTUR - INFO PEMASANGAN (komputer master)',
        '',
        "Alamat untuk komputer scan : $Url",
        "Kode pemasangan            : $PairingCode",
        '',
        'Simpan info ini. Saat memasang komputer scan, isi alamat dan kode di atas.'
    )
    if ($NetworkCategory -eq 'Public') {
        $lines += '', 'PERINGATAN: jaringan WiFi ini berstatus Public, komputer scan tidak bisa terhubung.',
            '  Ubah ke Private: Settings > Network & internet > Wi-Fi > (nama WiFi) > Network profile type: Private.'
    }
    if ($Dhcp) {
        $lines += '', 'PERINGATAN: alamat IP komputer ini dari DHCP dan bisa berubah.',
            '  Kunci IP di router (DHCP reservation) atau atur IP statis, supaya alamat di atas tetap.'
    }
    return $lines -join "`r`n"
}

function Write-HttpdConf {
    param(
        [Parameter(Mandatory)][string]$Template, [Parameter(Mandatory)][string]$Out,
        [Parameter(Mandatory)][string]$ServerRoot, [Parameter(Mandatory)][string]$AppPublic,
        [Parameter(Mandatory)][string]$PhpDir, [Parameter(Mandatory)][int]$Port
    )

    $slash = { param($p) $p.TrimEnd('\') -replace '\\', '/' }
    $text = ([IO.File]::ReadAllText($Template)).
        Replace('__SERVER_ROOT__', (& $slash $ServerRoot)).
        Replace('__APP_PUBLIC__', (& $slash $AppPublic)).
        Replace('__PHP_DIR__', (& $slash $PhpDir)).
        Replace('__PORT__', [string]$Port)
    Write-Utf8NoBom $Out $text
}

function Write-PhpIni {
    param([Parameter(Mandatory)][string]$Template, [Parameter(Mandatory)][string]$Out, [Parameter(Mandatory)][string]$PhpDir)

    Write-Utf8NoBom $Out (([IO.File]::ReadAllText($Template)).Replace('__PHP_DIR__', $PhpDir.TrimEnd('\')))
}

function New-ScanBatContent {
    # Isi "Pasang Titik N.bat": memasang komputer scan tanpa pertanyaan, memakai Setup.exe di folder yang sama.
    param([Parameter(Mandatory)][string]$SetupName, [Parameter(Mandatory)][ValidateSet(1, 2)][int]$Point, [Parameter(Mandatory)][string]$PairingCode)

    $setup = "%~dp0$SetupName"
    return @(
        '@echo off',
        "rem Pasang komputer scan titik $Point. Berisi kode pemasangan: hapus file ini setelah selesai.",
        "if not exist `"$setup`" (",
        "  echo File $SetupName tidak ditemukan. Jalankan dari flashdisk yang berisi file itu.",
        '  pause',
        '  exit /b 1',
        ')',
        "echo Memasang komputer scan titik $Point. Klik Yes bila Windows bertanya.",
        "`"$setup`" /SILENT /ROLE=scan /CABLE=1 /POINT=$Point /CODE=$PairingCode",
        'if errorlevel 1 (',
        '  echo Pemasangan belum berhasil. Baca pesannya, perbaiki, lalu jalankan lagi.',
        '  pause',
        ')',
        ''
    ) -join "`r`n"
}

function Write-ScanBats {
    # Tulis "Pasang Titik 1.bat" dan "Pasang Titik 2.bat" di sebelah Setup.exe (flashdisk). Mengembalikan path-nya.
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$SetupName, [Parameter(Mandatory)][string]$PairingCode)

    foreach ($point in 1, 2) {
        $path = Join-Path $Directory "Pasang Titik $point.bat"
        Write-Utf8NoBom $path (New-ScanBatContent -SetupName $SetupName -Point $point -PairingCode $PairingCode)
        $path
    }
}

Export-ModuleMember -Function Get-AppPort, New-EnvContent, New-PairingCode, Set-StorageLink, Remove-AppDir, Test-Junction, Get-InstallInfo, Write-HttpdConf, Write-PhpIni, New-ScanBatContent, Write-ScanBats
