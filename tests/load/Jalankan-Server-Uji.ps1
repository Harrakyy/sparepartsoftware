<#
  Server uji sementara dari stage\ (Apache + PHP + app hasil build), tanpa layanan/firewall/admin:
  app disalin ke %TEMP%\vf-uji-server, SQLite file (WAL, sama seperti di MGI), port 8099.
    .\Jalankan-Server-Uji.ps1            # mulai; cetak "SIAP <url>" lalu kembali (Apache tetap jalan)
    .\Jalankan-Server-Uji.ps1 -Stop      # hentikan & hapus folder uji
  Akun uji: bos / rahasia123 (superadmin).
#>
param(
    [string]$Stage = (Join-Path $PSScriptRoot '..\..\stage'),
    [int]$Port = 8099,
    [switch]$Stop
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\scripts\Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\scripts\Master.psm1') -Force

$dir = Join-Path $env:TEMP 'vf-uji-server'
$pidFile = Join-Path $dir 'httpd.pid'
if ($Stop) {
    if (Test-Path $pidFile) { Stop-Process -Id ([int](Get-Content $pidFile)) -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='httpd.exe'" | Where-Object { $_.CommandLine -match [regex]::Escape($dir) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Server uji dihentikan.'
    return
}

$stage = (Resolve-Path $Stage).Path
$phpDir = Join-Path $stage 'php'
$php = Join-Path $phpDir 'php.exe'
if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory -Force "$dir\php", "$dir\conf" | Out-Null

& robocopy (Join-Path $stage 'app') "$dir\app" /E /NFL /NDL /NJH /NJS /NP | Out-Null
& robocopy (Join-Path $stage 'storage-template') "$dir\app\storage" /E /NFL /NDL /NJH /NJS /NP | Out-Null

Write-PhpIni -Template (Join-Path $phpDir 'php.ini') -Out "$dir\php\php.ini" -PhpDir $phpDir
$db = Join-Path $dir 'database.sqlite'
New-Item -ItemType File $db | Out-Null
$envText = (New-EnvContent -DataDir $dir -BackupDir "$dir\backup" -Url "http://127.0.0.1:$Port") + "`nLICENSE_ENFORCE=false"
Write-Utf8NoBom "$dir\app\.env" $envText

$artisan = Join-Path $dir 'app\artisan'
& $php -c "$dir\php\php.ini" $artisan migrate --force | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'migrate gagal' }
& $php -c "$dir\php\php.ini" $artisan tinker --execute="App\Models\User::create(['name'=>'Bos Uji','username'=>'bos','password'=>'rahasia123','role'=>'superadmin','is_active'=>true]);" | Out-Null

$conf = "$dir\conf\httpd.conf"
Write-HttpdConf -Template (Join-Path $PSScriptRoot '..\..\templates\httpd.conf') -Out $conf `
    -ServerRoot (Join-Path $stage 'apache\Apache24') -AppPublic "$dir\app\public" -PhpDir $phpDir -Port $Port
# php.ini uji ada di folder uji (extension_dir menunjuk ke stage\php\ext).
$text = [IO.File]::ReadAllText($conf).Replace("PHPIniDir `"$(($phpDir -replace '\\', '/'))`"", "PHPIniDir `"$(("$dir\php" -replace '\\', '/'))`"")
$text = $text.Replace('ErrorLog "logs/error.log"', "ErrorLog `"$(("$dir\error.log" -replace '\\', '/'))`"").Replace('CustomLog "logs/access.log" common', "CustomLog `"$(("$dir\access.log" -replace '\\', '/'))`" common")
Write-Utf8NoBom $conf $text

$p = Start-Process (Join-Path $stage 'apache\Apache24\bin\httpd.exe') -ArgumentList '-f', "`"$conf`"" -PassThru -WindowStyle Hidden
Set-Content $pidFile $p.Id
for ($i = 0; $i -lt 30; $i++) {
    try { if ((Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$Port/up" -TimeoutSec 3).StatusCode -eq 200) { Write-Host "SIAP http://127.0.0.1:$Port"; return } } catch { Start-Sleep -Seconds 1 }
}
throw "Server uji tidak menjawab. Lihat $dir\error.log"
