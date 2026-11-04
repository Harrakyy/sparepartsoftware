<#
  Pasang komputer scan (tanpa PHP/Apache/database): sambung ke master, ikon Edge, dan tarik backup tiap jam.
    setup-scan.ps1 -Cable -Point 1|2 -PairingCode ABCD2345 [-AdapterIndex <n>] [-InstallDir C:\VerifikasiFaktur]
    setup-scan.ps1 -Server 192.168.1.10 -PairingCode ABCD2345              # tanpa kabel (alamat diketik)
    ... -CheckOnly -ResultFile <txt>                                         # hanya cek (halaman installer)
  -Cable: port LAN diberi alamat tetap (titik 1 = 192.168.77.2, titik 2 = .3); master dicari di
  192.168.77.1 port 80 lalu 8080. Gagal saat -CheckOnly → port LAN dikembalikan seperti semula.
  Exit 0 = sukses; 2 = koneksi/kode/alamat bermasalah (pesan di -ResultFile / install.log); 1 = galat lain.
#>
param(
    [string]$Server,
    [Parameter(Mandatory)][string]$PairingCode,
    [string]$InstallDir = 'C:\VerifikasiFaktur',
    [switch]$Cable,
    [ValidateSet(1, 2)][int]$Point = 1,
    [int]$AdapterIndex = 0,
    [switch]$CheckOnly,
    [string]$ResultFile
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Scan.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Cable.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Apply.psm1') -Force

$code = $PairingCode.Trim().ToUpper()
New-Item -ItemType Directory -Force $InstallDir | Out-Null
$cableState = Join-Path $InstallDir 'cable.json'

function Stop-WithMessage([string]$Message) {
    if ($ResultFile) { Write-Utf8NoBom $ResultFile $Message }
    Write-Host $Message
    exit 2
}

if ($Cable) {
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    $adapter = if ($AdapterIndex -gt 0) { $adapters | Where-Object InterfaceIndex -eq $AdapterIndex } else { Select-CableAdapter $adapters }
    if (-not $adapter) { Stop-WithMessage 'Port LAN tidak ditemukan. Pasang adaptor USB-LAN lalu coba lagi.' }
    try {
        # Alamat ganda terdeteksi Windows saat dipasang (DAD) → dikembalikan dan dilaporkan.
        Set-CableAddress -InterfaceIndex $adapter.InterfaceIndex -Address (Get-CableAddress -Role scan -Point $Point) -StateFile $cableState
    } catch {
        Stop-WithMessage "Titik scan $Point sudah dipakai komputer lain. Pilih titik scan yang lain. ($($_.Exception.Message))"
    }
    $found = Find-MasterUrl -Address (Get-CableAddress -Role master) -PairingCode $code
    if (-not $found.ok) {
        if ($CheckOnly) { Restore-CableAddress -StateFile $cableState }
        Stop-WithMessage $found.message
    }
    $url = $found.url
} else {
    if (-not $Server) { Stop-WithMessage 'Isi alamat komputer master.' }
    $check = Test-MasterConnection -Server $Server -PairingCode $code
    if (-not $check.ok) { Stop-WithMessage $check.message }
    $url = ConvertTo-ServerUrl $Server
}

if ($ResultFile) { Write-Utf8NoBom $ResultFile "Terhubung ke komputer master di $url." }
if ($CheckOnly) { exit 0 }

$backup = Join-Path $InstallDir 'backup'
New-Item -ItemType Directory -Force $backup | Out-Null
$log = Join-Path $InstallDir 'install.log'

try {
    Write-SetupLog $log "== Pasang komputer scan, master $url"
    $configFile = Join-Path $InstallDir 'scan.json'
    Write-Utf8NoBom $configFile (([ordered]@{ server = $url; pairingCode = $code; cable = [bool]$Cable; point = $Point }) | ConvertTo-Json)

    New-DesktopShortcut -Name 'Verifikasi Faktur' -Target (Get-EdgePath) -Arguments "--app=$url"

    $pull = Join-Path $InstallDir 'scripts\pull-backup.ps1'
    Register-RepeatingTask -Name 'TarikBackup' -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$pull`" -InstallDir `"$InstallDir`"" `
        -WorkingDirectory $InstallDir -Every (New-TimeSpan -Hours 1)

    # Kode pemasangan di scan.json: hanya Administrators & SYSTEM yang boleh membaca.
    Set-RestrictedAcl -Path $InstallDir -ReadUsers
    Set-RestrictedAcl -Path $backup
    & icacls $configFile /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' /Q | Out-Null

    Start-ScheduledTask -TaskPath '\VerifikasiFaktur\' -TaskName 'TarikBackup'
    Write-SetupLog $log 'Selesai.'
    exit 0
} catch {
    Write-SetupLog $log "GAGAL: $($_.Exception.Message)"
    exit 1
}
