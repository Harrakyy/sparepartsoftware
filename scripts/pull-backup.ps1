<#
  Tugas per jam di komputer scan: tarik backup terbaru dari master ke backup\perjam dan backup\harian.
  Gagal (master mati, WiFi putus) = salinan lama tetap; dicoba lagi jam berikutnya.
#>
param([string]$InstallDir = 'C:\VerifikasiFaktur')

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Scan.psm1') -Force

$log = Join-Path $InstallDir 'pull.log'
$config = Get-Content (Join-Path $InstallDir 'scan.json') -Raw | ConvertFrom-Json
$result = Invoke-BackupPull -Server $config.server -PairingCode $config.pairingCode -BackupDir (Join-Path $InstallDir 'backup')

$line = '{0:yyyy-MM-dd HH:mm}  {1}' -f (Get-Date), $result.message
$lines = @(Get-Content $log -ErrorAction SilentlyContinue | Select-Object -Last 499) + $line
Set-Content $log $lines -Encoding UTF8
if (-not $result.ok) { exit 1 }
