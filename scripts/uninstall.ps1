<#
  Dijalankan saat aplikasi dicopot (master maupun scan): hapus layanan, tugas jadwal, aturan firewall, dan ikon;
  kembalikan port LAN (alamat otomatis) dan setelan daya seperti sebelum dipasang.
  Tiap langkah berdiri sendiri: satu yang gagal dicatat (uninstall.log) dan langkah lain tetap jalan —
  layanan & tugas jadwal tidak boleh tertinggal menunjuk ke php/httpd yang sudah dihapus.
  data\ (database, PDF, lisensi, .env) dan backup\ SENGAJA dibiarkan; hapus manual bila benar-benar tak dipakai.
#>
param([string]$InstallDir = 'C:\VerifikasiFaktur')

$ErrorActionPreference = 'Continue'
$log = Join-Path $env:TEMP 'VerifikasiFaktur-uninstall.log'

function Step([string]$Name, [scriptblock]$Action) {
    try {
        & $Action
    } catch {
        Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  GAGAL {1}: {2}' -f (Get-Date), $Name, $_.Exception.Message) -Encoding UTF8
    }
}

Step 'modul' { Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force; Import-Module (Join-Path $PSScriptRoot 'Apply.psm1') -Force }

Step 'layanan' {
    if (Get-Service 'VerifikasiFaktur' -ErrorAction SilentlyContinue) {
        Stop-Service 'VerifikasiFaktur' -Force -ErrorAction SilentlyContinue
        & sc.exe delete 'VerifikasiFaktur' | Out-Null
    }
}
Step 'tugas jadwal' { Get-ScheduledTask -TaskPath '\VerifikasiFaktur\' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false }
Step 'firewall' { Get-NetFirewallRule -DisplayName 'Verifikasi Faktur*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule }
Step 'ikon' { foreach ($n in 'Verifikasi Faktur', 'Reset superadmin', 'Info pemasangan') { Remove-DesktopShortcut $n } }

# Lepas junction app\storage supaya penghapusan file app tidak pernah menyentuh data\storage.
Step 'junction' {
    $link = Join-Path $InstallDir 'app\storage'
    if ((Test-Path $link) -and ((Get-Item $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        cmd /c rmdir "$link" | Out-Null
    }
}

# Terakhir: kembalikan port LAN dan setelan daya.
foreach ($state in (Join-Path $InstallDir 'data\cable.json'), (Join-Path $InstallDir 'cable.json')) {
    Step "port LAN ($state)" { Restore-CableAddress -StateFile $state }
}
Step 'setelan daya' { Restore-KeepAwake -StateFile (Join-Path $InstallDir 'data\power.json') }
exit 0
