<#
  Dijalankan installer SEBELUM file versi baru disalin (hanya bila master sudah terpasang):
  hentikan layanan & jadwal, backup "sebelum-update", lalu hapus app\ lama dengan aman
  (junction app\storage dilepas dulu, sehingga data\storage tidak tersentuh).
  Exit ≠ 0 = update dibatalkan (data tidak diubah).
#>
param([string]$InstallDir = 'C:\VerifikasiFaktur')

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Master.psm1') -Force

$app = Join-Path $InstallDir 'app'
$php = Join-Path $InstallDir 'php\php.exe'
if (-not (Test-Path (Join-Path $app 'artisan'))) { exit 0 }

$data = Join-Path $InstallDir 'data'
New-Item -ItemType Directory -Force $data | Out-Null
$log = Join-Path $data 'install.log'

try {
    Write-SetupLog $log '== Persiapan update'
    Disable-ScheduledTask -TaskPath '\VerifikasiFaktur\' -TaskName 'Jadwal' -ErrorAction SilentlyContinue | Out-Null
    Stop-Service 'VerifikasiFaktur' -Force -ErrorAction SilentlyContinue

    Write-SetupLog $log 'Backup sebelum-update'
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $php (Join-Path $app 'artisan') app:backup sebelum-update 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $prev }
    Add-Content $log ($out -join "`r`n") -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw "Backup sebelum-update gagal; update dibatalkan supaya data aman. $($out -join ' ')" }

    Write-SetupLog $log 'Hapus app lama (data tetap)'
    Remove-AppDir -AppDir $app
    exit 0
} catch {
    Write-SetupLog $log "GAGAL: $($_.Exception.Message)"
    Start-Service 'VerifikasiFaktur' -ErrorAction SilentlyContinue
    Enable-ScheduledTask -TaskPath '\VerifikasiFaktur\' -TaskName 'Jadwal' -ErrorAction SilentlyContinue | Out-Null
    exit 1
}
