<#
  Build installer Verifikasi Faktur.
    .\build.ps1                  # app dari tag v<AppVersion> di ..\sparepart
    .\build.ps1 -AppRef HEAD     # build uji dari commit terakhir
    .\build.ps1 -SkipInno        # hanya siapkan stage\ (tanpa kompilasi Setup.exe)
  Butuh: git, composer, PHP >= MinPhp di PATH (untuk composer), Inno Setup 6 (kecuali -SkipInno).
#>
param(
    [string]$AppRepo = (Join-Path $PSScriptRoot '..\sparepart'),
    [string]$AppRef,
    [switch]$SkipInno
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot 'build\Build.psm1') -Force

$v = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'versions.psd1')
if (-not $AppRef) { $AppRef = "v$($v.AppVersion)" }
$cache = Join-Path $PSScriptRoot 'cache'
$stage = Join-Path $PSScriptRoot 'stage'

function Invoke-Native([string]$What, [scriptblock]$Run) {
    # PowerShell 5.1 + Stop: baris stderr apa pun (progres composer/git) dianggap galat fatal.
    # Alirkan stderr sebagai teks biasa; sukses/gagal hanya dari exit code.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Run 2>&1 | ForEach-Object { Write-Host "   $_" }
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($LASTEXITCODE -ne 0) { throw "$What gagal (exit $LASTEXITCODE)" }
}

$started = Get-Date
function Expand-Zip([string]$Zip, [string]$Dest) {
    # tar bawaan Windows 10+ jauh lebih cepat dari Expand-Archive PowerShell 5.1.
    New-Item -ItemType Directory -Force $Dest | Out-Null
    Invoke-Native "ekstrak $(Split-Path $Zip -Leaf)" { & (Join-Path $env:SystemRoot 'System32\tar.exe') -xf $Zip -C $Dest }
}
function Write-Step([string]$Text) { Write-Host ('== [{0:mm\:ss}] {1}' -f ((Get-Date) - $started), $Text) }

Write-Step "Stage bersih"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory $stage | Out-Null

Write-Step "Unduh & verifikasi paket"
$phpZip = Get-VerifiedFile -Url $v.Php.Url -Sha256 $v.Php.Sha256 -CacheDir $cache
$apacheZip = Get-VerifiedFile -Url $v.Apache.Url -Sha256 $v.Apache.Sha256 -CacheDir $cache
$vcRedist = Get-VerifiedFile -Url $v.VcRedist.Url -Sha256 $v.VcRedist.Sha256 -CacheDir $cache
Expand-Zip $phpZip (Join-Path $stage 'php')
Expand-Zip $apacheZip (Join-Path $stage 'apache')
Copy-Item $vcRedist $stage

Write-Step "Gerbang versi PHP"
$phpVersion = (& (Join-Path $stage 'php\php.exe') -n -r 'echo PHP_VERSION;')
if (-not (Test-PhpVersion -Actual $phpVersion -Minimum $v.MinPhp)) {
    throw "PHP di paket $phpVersion di bawah minimum $($v.MinPhp) (celah keamanan). Perbarui versions.psd1."
}
Copy-Item (Join-Path $PSScriptRoot 'templates\php.ini') (Join-Path $stage 'php\php.ini')

Write-Step "App $AppRef dari $AppRepo"
$appZip = Join-Path $cache 'app.zip'
Invoke-Native 'git archive' { git -C $AppRepo archive --format=zip -o $appZip $AppRef }
$appCommit = (git -C $AppRepo rev-parse --short $AppRef)
$appDir = Join-Path $stage 'app'
Expand-Zip $appZip $appDir
# Data persisten (PDF, lisensi, log, sesi) hidup di data\storage; app\storage jadi junction saat dipasang.
Move-Item (Join-Path $appDir 'storage') (Join-Path $stage 'storage-template')

Write-Step "composer install + audit"
Push-Location $appDir
try {
    Invoke-Native 'composer install' { composer install --no-dev --optimize-autoloader --no-interaction --no-progress }
    Invoke-Native 'composer audit (ada celah keamanan dependensi)' { composer audit --no-dev --abandoned=report }
} finally {
    Pop-Location
}

Write-Step "Periksa file rahasia"
Assert-CleanStage -StageDir $stage

$info = [ordered]@{ app = $v.AppVersion; appCommit = $appCommit; php = $phpVersion; apache = $v.Apache.Version; vcRedist = $v.VcRedist.Version }
$info | ConvertTo-Json | Set-Content (Join-Path $stage 'build.json') -Encoding UTF8

if ($SkipInno) {
    Write-Host "Stage siap di $stage (Inno dilewati)."
    return
}

Write-Step "Kompilasi Setup.exe (Inno Setup)"
$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 tidak ditemukan (winget install JRSoftware.InnoSetup).' }
$dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
Invoke-Native 'ISCC' { & $iscc /Q "/DAppVersion=$($v.AppVersion)" "/DStageDir=$stage" (Join-Path $PSScriptRoot 'installer\VerifikasiFaktur.iss') }

$setup = Join-Path $dist "Verifikasi-Faktur-Setup-$($v.AppVersion).exe"

Write-Step "Scan Windows Defender"
# Installer Inno kadang dianggap trojan (false positive): ketahuan di sini, bukan di komputer pelanggan.
$defender = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
$scan = (& $defender -Scan -ScanType 3 -File $setup -DisableRemediation 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $scan -notmatch 'found no threats') {
    throw "Windows Defender menandai $setup. Jangan dibagikan; periksa/kirim ke Microsoft. $($scan.Trim())"
}
$notes = @(
    "Verifikasi Faktur $($v.AppVersion) - catatan rilis",
    "Tanggal build : $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
    "App           : $($v.AppVersion) (commit $appCommit, ref $AppRef)",
    "PHP           : $phpVersion",
    "Apache        : $($v.Apache.Version)",
    "VC++ runtime  : $($v.VcRedist.Version)",
    "Setup.exe     : $(Split-Path $setup -Leaf)",
    "SHA-256       : $((Get-FileHash $setup -Algorithm SHA256).Hash)",
    "Defender      : bersih (MpCmdRun -ScanType 3)"
)
Set-Content (Join-Path $dist 'RELEASE-NOTES.txt') $notes -Encoding UTF8
Write-Step "Selesai: $setup ($([math]::Round((Get-Item $setup).Length / 1MB)) MB)"
