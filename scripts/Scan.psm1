# Logika komputer scan: cek koneksi ke master dan tarik salinan backup per jam (diuji Pester).

Set-StrictMode -Version Latest

$KeepHourly = 24
$KeepDaily = 7

function ConvertTo-ServerUrl([string]$Server) {
    $s = $Server.Trim().TrimEnd('/')
    if ($s -notmatch '^https?://') { $s = "http://$s" }
    return $s
}

$DefaultGet = {
    # Status HTTP (int); galat jaringan dilempar. HEAD supaya cek kode tidak mengunduh database.
    param($Url, $Headers)
    try {
        (Invoke-WebRequest -UseBasicParsing -Method Head -Uri $Url -Headers $Headers -TimeoutSec 10).StatusCode
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { throw }
    }
}

$DefaultDownload = {
    param($Url, $Headers, $OutFile)
    Invoke-WebRequest -UseBasicParsing -Uri $Url -Headers $Headers -OutFile $OutFile -TimeoutSec 120
}

function Test-MasterConnection {
    param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][string]$PairingCode, [scriptblock]$Get = $DefaultGet)

    $url = ConvertTo-ServerUrl $Server
    $unreachable = "Tidak bisa terhubung ke komputer master di $url. Pastikan satu WiFi, alamatnya benar, dan master menyala."
    try {
        if ((& $Get "$url/up" @{}) -ne 200) { return @{ ok = $false; message = $unreachable } }
        $status = & $Get "$url/backup/latest" @{ 'X-Pairing-Code' = $PairingCode }
    } catch {
        return @{ ok = $false; message = $unreachable }
    }
    if ($status -eq 403) { return @{ ok = $false; message = 'Kode pemasangan salah.' } }
    if ($status -in 200, 404) { return @{ ok = $true; message = "Terhubung ke $url." } }  # 404 = master belum punya backup
    return @{ ok = $false; message = "Komputer master menjawab tidak normal (status $status)." }
}

function Find-MasterUrl {
    <#
      Mode kabel: master di alamat tetap, port 80 atau 8080. Dicoba berulang sampai WaitSeconds (port LAN
      yang baru diberi alamat butuh beberapa detik). Kode salah = berhenti saat itu juga.
    #>
    param(
        [Parameter(Mandatory)][string]$Address, [Parameter(Mandatory)][string]$PairingCode,
        [scriptblock]$Get = $DefaultGet, [int]$WaitSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        foreach ($url in "http://$Address", "http://${Address}:8080") {
            $r = Test-MasterConnection -Server $url -PairingCode $PairingCode -Get $Get
            if ($r.ok) { return @{ ok = $true; url = $url; message = $r.message } }
            if ($r.message -eq 'Kode pemasangan salah.') { return @{ ok = $false; url = $null; message = $r.message } }
        }
        if ((Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    } while ((Get-Date) -lt $deadline)

    return @{ ok = $false; url = $null; message = ("Tidak bisa terhubung ke komputer master di $Address. Pastikan kabel LAN tercolok ke switch " +
        '(lampu port menyala), komputer master menyala, dan aplikasinya sudah dipasang.') }
}

function Test-SqliteFile([string]$Path) {
    $header = [Text.Encoding]::ASCII.GetBytes("SQLite format 3`0")
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt $header.Length) { return $false }
    for ($i = 0; $i -lt $header.Length; $i++) { if ($bytes[$i] -ne $header[$i]) { return $false } }
    return $true
}

function Remove-OldCopies([string]$Dir, [int]$Keep) {
    Get-ChildItem $Dir -File -Filter 'faktur-*.sqlite' | Sort-Object Name -Descending | Select-Object -Skip $Keep | Remove-Item -Force
}

function Invoke-BackupPull {
    <#
      Unduh backup terbaru master ke file sementara. Gagal / bukan database → salinan lama tidak disentuh.
      Isi sama dengan salinan per-jam terakhir → dibuang. Selain itu simpan per-jam, satu harian per hari,
      lalu rotasi 24 per jam + 7 harian.
    #>
    param(
        [Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][string]$PairingCode,
        [Parameter(Mandatory)][string]$BackupDir, [scriptblock]$Download = $DefaultDownload, [datetime]$Now = (Get-Date)
    )

    $hourly = Join-Path $BackupDir 'perjam'
    $daily = Join-Path $BackupDir 'harian'
    New-Item -ItemType Directory -Force $hourly, $daily | Out-Null
    $temp = Join-Path $BackupDir ".tmp-$([guid]::NewGuid()).sqlite"

    try {
        & $Download "$(ConvertTo-ServerUrl $Server)/backup/latest" @{ 'X-Pairing-Code' = $PairingCode } $temp
        if (-not (Test-SqliteFile $temp)) { return @{ ok = $false; message = 'Jawaban master bukan database SQLite; salinan tidak disimpan.' } }

        $last = Get-ChildItem $hourly -File -Filter 'faktur-*.sqlite' | Sort-Object Name -Descending | Select-Object -First 1
        if ($last -and (Get-FileHash $last.FullName).Hash -eq (Get-FileHash $temp).Hash) {
            return @{ ok = $true; message = 'Data tidak berubah, salinan dilewati.' }
        }

        $name = 'faktur-{0:yyyyMMdd-HHmm}.sqlite' -f $Now
        $saved = Join-Path $hourly $name
        Move-Item $temp $saved -Force
        if (-not (Get-ChildItem $daily -File -Filter ('faktur-{0:yyyyMMdd}-*.sqlite' -f $Now))) {
            Copy-Item $saved (Join-Path $daily $name)
        }
        Remove-OldCopies $hourly $KeepHourly
        Remove-OldCopies $daily $KeepDaily
        return @{ ok = $true; message = "Disimpan: $saved" }
    } catch {
        return @{ ok = $false; message = "Gagal menarik backup: $($_.Exception.Message)" }
    } finally {
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Test-MasterConnection, Find-MasterUrl, Invoke-BackupPull, ConvertTo-ServerUrl
