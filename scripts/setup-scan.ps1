<#
  Pasang komputer scan (tanpa PHP/Apache/database): cek koneksi ke master, ikon Edge, dan tarik backup tiap jam.
    setup-scan.ps1 -Server 192.168.1.10 -PairingCode ABCD2345 [-InstallDir C:\VerifikasiFaktur]
    setup-scan.ps1 ... -CheckOnly -ResultFile <txt>   # hanya cek (dipakai halaman installer)
  Exit 0 = sukses; 2 = koneksi/kode salah (pesan di -ResultFile / install.log); 1 = galat lain.
#>
param(
    [Parameter(Mandatory)][string]$Server,
    [Parameter(Mandatory)][string]$PairingCode,
    [string]$InstallDir = 'C:\VerifikasiFaktur',
    [switch]$CheckOnly,
    [string]$ResultFile
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Scan.psm1') -Force

$check = Test-MasterConnection -Server $Server -PairingCode $PairingCode.Trim().ToUpper()
if ($ResultFile) { Write-Utf8NoBom $ResultFile $check.message }
if (-not $check.ok) { Write-Host $check.message; exit 2 }
if ($CheckOnly) { exit 0 }

$backup = Join-Path $InstallDir 'backup'
New-Item -ItemType Directory -Force $InstallDir, $backup | Out-Null
$log = Join-Path $InstallDir 'install.log'

try {
    $url = ConvertTo-ServerUrl $Server
    Write-SetupLog $log "== Pasang komputer scan, master $url"
    $config = [ordered]@{ server = $url; pairingCode = $PairingCode.Trim().ToUpper() }
    $configFile = Join-Path $InstallDir 'scan.json'
    Write-Utf8NoBom $configFile ($config | ConvertTo-Json)

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
