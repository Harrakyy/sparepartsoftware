# Fungsi bersama skrip master dan scan.

Set-StrictMode -Version Latest

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    # PowerShell 5.1 menulis BOM pada -Encoding UTF8; Apache, php.ini, dan .env tidak menerima BOM.
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

function Register-RepeatingTask {
    <#
      Tugas Task Scheduler berulang, akun SYSTEM, tetap jalan saat laptop pakai baterai (default schtasks
      hanya jalan saat dicolok listrik — backup bisa diam-diam berhenti), dan tidak menumpuk bila masih jalan.
    #>
    param(
        [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Execute, [string]$Argument = '',
        [Parameter(Mandatory)][string]$WorkingDirectory, [Parameter(Mandatory)][TimeSpan]$Every
    )

    $action = New-ScheduledTaskAction -Execute $Execute -Argument $Argument -WorkingDirectory $WorkingDirectory
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval $Every -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskPath '\VerifikasiFaktur\' -TaskName $Name -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
}

function Get-EdgePath {
    foreach ($p in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")) {
        if (Test-Path $p) { return $p }
    }
    throw 'Microsoft Edge tidak ditemukan.'
}

function New-DesktopShortcut {
    # Ikon di desktop semua pengguna (Public Desktop). -RunAsAdmin menyalakan bendera "Run as administrator".
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Target, [string]$Arguments = '',
        [string]$WorkingDirectory = '', [string]$Icon = '', [switch]$RunAsAdmin)

    $path = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) "$Name.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($path)
    $lnk.TargetPath = $Target
    $lnk.Arguments = $Arguments
    if ($WorkingDirectory) { $lnk.WorkingDirectory = $WorkingDirectory }
    if ($Icon) { $lnk.IconLocation = $Icon }
    $lnk.Save()
    if ($RunAsAdmin) {
        $bytes = [IO.File]::ReadAllBytes($path)
        $bytes[0x15] = $bytes[0x15] -bor 0x20  # SLDF_RUNAS_USER
        [IO.File]::WriteAllBytes($path, $bytes)
    }
}

function Remove-DesktopShortcut([string]$Name) {
    Remove-Item (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) "$Name.lnk") -Force -ErrorAction SilentlyContinue
}

function Set-RestrictedAcl {
    <#
      Hanya Administrators & SYSTEM yang boleh mengubah; -ReadUsers memberi Users hak baca/jalankan.
      Pakai SID (bukan nama grup) karena nama grup berbeda di Windows bahasa Indonesia.
    #>
    param([Parameter(Mandatory)][string]$Path, [switch]$ReadUsers)

    $grants = @('*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F')
    if ($ReadUsers) { $grants += '*S-1-5-32-545:(OI)(CI)RX' }

    # 1) Semua isinya dulu (selagi masih bisa dibaca): hapus entri sendiri, warisi dari folder di atasnya.
    if (Get-ChildItem $Path -Force | Select-Object -First 1) {
        & icacls (Join-Path $Path '*') /reset /T /C /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Gagal menerapkan izin ke isi folder $Path" }
    }

    # 2) Folder ini saja (TANPA /T): putus pewarisan, pasang izin dengan bendera pewarisan (OI)(CI);
    #    Windows meneruskannya ke semua isi yang mewarisi. /T di sini akan menulis entri (OI)(CI) ke
    #    setiap FILE — bendera itu tak berlaku untuk file, sehingga file berakhir tanpa izin apa pun
    #    (Apache 403, admin pun tak bisa membaca).
    $arguments = @($Path, '/inheritance:r') + ($grants | ForEach-Object { '/grant:r'; $_ })
    if (-not $ReadUsers) {
        # Users / Authenticated Users / Everyone yang tertulis eksplisit (mis. dari folder induk) dicabut.
        $arguments += '/remove:g', '*S-1-5-32-545', '*S-1-5-11', '*S-1-1-0'
    }
    & icacls @($arguments + '/Q') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Gagal mengatur izin folder $Path" }
}

function Write-SetupLog([string]$LogFile, [string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $Message
}

Export-ModuleMember -Function Write-Utf8NoBom, Register-RepeatingTask, Get-EdgePath, New-DesktopShortcut, Remove-DesktopShortcut, Set-RestrictedAcl, Write-SetupLog
