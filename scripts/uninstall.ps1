<#
  Dijalankan saat aplikasi dicopot (master maupun scan): hapus layanan, tugas jadwal, aturan firewall, dan ikon;
  kembalikan port LAN (alamat otomatis) dan setelan daya seperti sebelum dipasang.
  data\ (database, PDF, lisensi, .env) dan backup\ SENGAJA dibiarkan; hapus manual bila benar-benar tak dipakai.
#>
param([string]$InstallDir = 'C:\VerifikasiFaktur')

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Apply.psm1') -Force

foreach ($state in (Join-Path $InstallDir 'data\cable.json'), (Join-Path $InstallDir 'cable.json')) {
    Restore-CableAddress -StateFile $state
}
Remove-CableFirewallRule
Restore-KeepAwake -StateFile (Join-Path $InstallDir 'data\power.json')
Remove-DesktopShortcut 'Info pemasangan'

$service = 'VerifikasiFaktur'
if (Get-Service $service -ErrorAction SilentlyContinue) {
    Stop-Service $service -Force -ErrorAction SilentlyContinue
    & sc.exe delete $service | Out-Null
}
Get-ScheduledTask -TaskPath '\VerifikasiFaktur\' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
Get-NetFirewallRule -DisplayName 'Verifikasi Faktur' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Remove-DesktopShortcut 'Verifikasi Faktur'
Remove-DesktopShortcut 'Reset superadmin'

# Lepas junction app\storage supaya penghapusan file app tidak pernah menyentuh data\storage.
$link = Join-Path $InstallDir 'app\storage'
if ((Test-Path $link) -and ((Get-Item $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    cmd /c rmdir "$link" | Out-Null
}
exit 0
