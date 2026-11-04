<#
  Pasang / perbarui komputer master. Dipanggil installer setelah file tersalin (hak admin).
    setup-master.ps1 [-InstallDir C:\VerifikasiFaktur] [-VcRedist <exe>] [-RestoreFrom <backup.sqlite>]
                     [-Cable [-AdapterIndex <n>]] [-Port <n>] [-KeepAwake]
  -Cable: port LAN diberi alamat tetap 192.168.77.1 untuk komputer scan (lewat switch).
  Aman dijalankan ulang: .env (APP_KEY, kode pemasangan), database, PDF, dan lisensi tetap.
  Exit 0 = sukses; selain itu lihat data\install.log.
#>
param(
    [string]$InstallDir = 'C:\VerifikasiFaktur',
    [string]$VcRedist,
    [string]$RestoreFrom,
    [switch]$Cable,
    [int]$AdapterIndex = 0,
    [int]$Port = 0,
    [switch]$KeepAwake
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Master.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Cable.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Apply.psm1') -Force

$app = Join-Path $InstallDir 'app'
$phpDir = Join-Path $InstallDir 'php'
$php = Join-Path $phpDir 'php.exe'
$apache = Join-Path $InstallDir 'apache\Apache24'
$httpd = Join-Path $apache 'bin\httpd.exe'
$data = Join-Path $InstallDir 'data'
$backup = Join-Path $InstallDir 'backup'
$db = Join-Path $data 'database.sqlite'
$installJson = Join-Path $data 'install.json'
$service = 'VerifikasiFaktur'
New-Item -ItemType Directory -Force $data, $backup | Out-Null
$log = Join-Path $data 'install.log'

function Invoke-Checked([string]$What, [string]$Exe, [string[]]$Arguments) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $prev }
    if ($out) { Add-Content $log ($out -join "`r`n") -Encoding UTF8 }
    if ($LASTEXITCODE -ne 0) { throw "$What gagal (exit $LASTEXITCODE): $(($out | Select-Object -Last 3) -join ' ')" }
}

function Invoke-Artisan([string[]]$Arguments) {
    Invoke-Checked "artisan $($Arguments -join ' ')" $php (@((Join-Path $app 'artisan')) + $Arguments)
}

function Get-LanAddress {
    $cfg = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
    if (-not $cfg) { return @{ Ip = '127.0.0.1'; Dhcp = $false; Category = 'Private' } }
    $iface = Get-NetIPInterface -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4
    $connection = Get-NetConnectionProfile -InterfaceIndex $cfg.InterfaceIndex -ErrorAction SilentlyContinue
    return @{
        Ip       = @($cfg.IPv4Address)[0].IPAddress
        Dhcp     = ($iface.Dhcp -eq 'Enabled')
        Category = $(if ($connection) { [string]$connection.NetworkCategory } else { 'Private' })
    }
}

function Wait-AppUp([string]$Url) {
    for ($i = 0; $i -lt 30; $i++) {
        try {
            if ((Invoke-WebRequest -UseBasicParsing -Uri "$Url/up" -TimeoutSec 5).StatusCode -eq 200) { return }
        } catch { Start-Sleep -Seconds 1 }
    }
    $tail = Get-Content (Join-Path $apache 'logs\error.log') -Tail 5 -ErrorAction SilentlyContinue
    throw "Aplikasi tidak menjawab di $Url/up. Log Apache: $($tail -join ' | ')"
}

try {
    Write-SetupLog $log "== Pasang master di $InstallDir"

    if ($VcRedist -and (Test-Path $VcRedist)) {
        Write-SetupLog $log 'Visual C++ runtime'
        $p = Start-Process $VcRedist -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
        if ($p.ExitCode -notin 0, 1638, 3010) { throw "Visual C++ runtime gagal dipasang (exit $($p.ExitCode))" }
    }

    $previous = if (Test-Path $installJson) { Get-Content $installJson -Raw | ConvertFrom-Json } else { $null }
    $port = if ($Port -gt 0) { $Port } else { Get-AppPort -Previous $(if ($previous) { [int]$previous.port } else { 0 }) }
    $suffix = if ($port -eq 80) { '' } else { ":$port" }
    $net = Get-LanAddress
    $lanUrl = if ($Cable) { "http://$(Get-CableAddress -Role master)$suffix" } else { "http://$($net.Ip)$suffix" }
    $localUrl = "http://localhost$suffix"
    Write-SetupLog $log "Port $port, alamat $lanUrl"

    Write-SetupLog $log 'Konfigurasi (.env, php.ini, storage)'
    $envFile = Join-Path $data '.env'
    $existing = if (Test-Path $envFile) { [IO.File]::ReadAllText($envFile) } else { $null }
    $envText = New-EnvContent -Existing $existing -DataDir $data -BackupDir $backup -Url $lanUrl
    Write-Utf8NoBom $envFile $envText
    Copy-Item $envFile (Join-Path $app '.env') -Force
    $pairingCode = ([regex]::Match($envText, '(?m)^APP_PAIRING_CODE=(.+)$')).Groups[1].Value
    Write-PhpIni -Template (Join-Path $phpDir 'php.ini') -Out (Join-Path $phpDir 'php.ini') -PhpDir $phpDir
    Set-StorageLink -AppDir $app -DataDir $data -TemplateDir (Join-Path $InstallDir 'storage-template')

    if ($RestoreFrom) {
        Write-SetupLog $log "Pulihkan database dari $RestoreFrom"
        $check = & $php -r "echo (new PDO('sqlite:'.`$argv[1]))->query('PRAGMA integrity_check')->fetchColumn();" $RestoreFrom 2>$null
        if ($check -ne 'ok') { throw "File backup $RestoreFrom rusak atau bukan database (integrity_check: $check)." }
        if (Test-Path $db) { Move-Item $db "$db.sebelum-pulihkan-$(Get-Date -Format yyyyMMdd-HHmm)" }
        Copy-Item $RestoreFrom $db
    }
    if (-not (Test-Path $db)) { New-Item -ItemType File $db | Out-Null }

    Write-SetupLog $log 'Database (migrasi) dan cache'
    Invoke-Artisan @('migrate', '--force')
    Invoke-Artisan @('optimize')

    Write-SetupLog $log 'Apache (layanan Windows)'
    Write-HttpdConf -Template (Join-Path $InstallDir 'templates\httpd.conf') -Out (Join-Path $apache 'conf\httpd.conf') `
        -ServerRoot $apache -AppPublic (Join-Path $app 'public') -PhpDir $phpDir -Port $port
    Invoke-Checked 'Cek konfigurasi Apache' $httpd @('-t')
    if (-not (Get-Service $service -ErrorAction SilentlyContinue)) {
        Invoke-Checked 'Daftarkan layanan Apache' $httpd @('-k', 'install', '-n', $service)
    }
    Set-Service $service -StartupType Automatic
    & sc.exe failure $service reset= 86400 actions= restart/5000/restart/5000/restart/30000 | Out-Null
    Restart-Service $service -Force
    Wait-AppUp $localUrl

    # Mode kabel: HANYA aturan kabel (192.168.77.x). Aturan Private umum akan membuka app (termasuk
    # /daftar) ke seluruh jaringan kantor bila WiFi/LAN kantor berstatus Private.
    Get-NetFirewallRule -DisplayName 'Verifikasi Faktur' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    if (-not $Cable) {
        Write-SetupLog $log 'Firewall (profil Private)'
        New-NetFirewallRule -DisplayName 'Verifikasi Faktur' -Direction Inbound -Protocol TCP -LocalPort $port -Profile Private -Action Allow | Out-Null
    }

    if ($Cable) {
        Write-SetupLog $log 'Port LAN untuk kabel (192.168.77.1) + firewall kabel'
        $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
        $adapter = if ($AdapterIndex -gt 0) { $adapters | Where-Object InterfaceIndex -eq $AdapterIndex } else { Select-CableAdapter $adapters }
        if (-not $adapter) { throw 'Port LAN tidak ditemukan. Pasang adaptor USB-LAN lalu ulangi.' }
        Set-CableAddress -InterfaceIndex $adapter.InterfaceIndex -Address (Get-CableAddress -Role master) -StateFile (Join-Path $data 'cable.json')
        Set-CableFirewallRule -Port $port
    }
    if ($KeepAwake) {
        Write-SetupLog $log 'Jangan sleep saat dicolok listrik'
        Set-KeepAwake -StateFile (Join-Path $data 'power.json')
    }

    Write-SetupLog $log 'Jadwal (hapus file lama, backup per jam & harian)'
    Register-RepeatingTask -Name 'Jadwal' -Execute $php -Argument "`"$(Join-Path $app 'artisan')`" schedule:run" `
        -WorkingDirectory $app -Every (New-TimeSpan -Minutes 1)
    Enable-ScheduledTask -TaskPath '\VerifikasiFaktur\' -TaskName 'Jadwal' | Out-Null

    Write-SetupLog $log 'Ikon desktop dan izin folder'
    New-DesktopShortcut -Name 'Verifikasi Faktur' -Target (Get-EdgePath) -Arguments "--app=$localUrl"
    New-DesktopShortcut -Name 'Reset superadmin' -Target "$env:SystemRoot\System32\cmd.exe" `
        -Arguments "/k `"`"$php`" `"$(Join-Path $app 'artisan')`" app:superadmin --reset`"" -WorkingDirectory $app -RunAsAdmin
    New-DesktopShortcut -Name 'Info pemasangan' -Target (Join-Path $env:SystemRoot 'notepad.exe') -Arguments "`"$(Join-Path $InstallDir 'INFO-PEMASANGAN.txt')`""
    Set-RestrictedAcl -Path $InstallDir -ReadUsers
    Set-RestrictedAcl -Path $data
    Set-RestrictedAcl -Path $backup

    # Mode kabel: komputer scan memakai alamat tetap lewat aturan firewall kabel, jadi status WiFi/DHCP tak relevan.
    $info = if ($Cable) { Get-InstallInfo -Url $lanUrl -PairingCode $pairingCode } else { Get-InstallInfo -Url $lanUrl -PairingCode $pairingCode -NetworkCategory $net.Category -Dhcp $net.Dhcp }
    Write-Utf8NoBom (Join-Path $InstallDir 'INFO-PEMASANGAN.txt') $info
    $build = Get-Content (Join-Path $InstallDir 'build.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    $state = [ordered]@{ port = $port; cable = [bool]$Cable; url = $lanUrl; localUrl = $localUrl; version = $(if ($build) { $build.app } else { '' }) }
    Write-Utf8NoBom $installJson ($state | ConvertTo-Json)
    Write-Utf8NoBom (Join-Path $data 'local-url.txt') $localUrl  # dibaca halaman akhir installer (tautan aktivasi)

    Write-SetupLog $log "Selesai. Buka $localUrl/aktivasi untuk aktivasi lisensi."
    exit 0
} catch {
    Write-SetupLog $log "GAGAL: $($_.Exception.Message)"
    exit 1
}
