<#
  Pemeriksaan komputer sebelum pasang (halaman pertama installer). Tidak mengubah apa pun.
    preflight.ps1 -Role master|scan -ResultFile <txt> [-AdapterIndex <n>]
  ResultFile: satu baris per pemeriksaan "[OK] / [!] / [X] Nama: pesan".
  <ResultFile>.adapters: "index|nama (deskripsi)" untuk pilihan port LAN bila ada lebih dari satu.
  <ResultFile>.adapter: index port LAN terpilih. Exit 0 = boleh lanjut, 2 = ada yang menahan.
#>
param(
    [Parameter(Mandatory)][ValidateSet('master', 'scan')][string]$Role,
    [Parameter(Mandatory)][string]$ResultFile,
    [int]$AdapterIndex = 0,
    [string]$InstallDir = 'C:\VerifikasiFaktur'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Cable.psm1') -Force

$adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
    Select-Object InterfaceIndex, Name, InterfaceDescription, Status, Virtual, MediaType, PhysicalMediaType)
$wired = @($adapters | Where-Object { (Select-CableAdapter @($_)) })
$adapter = if ($AdapterIndex -gt 0) { $wired | Where-Object { $_.InterfaceIndex -eq $AdapterIndex } | Select-Object -First 1 } else { Select-CableAdapter $adapters }

$hasGateway = $false
$dhcpAddress = $null
if ($adapter) {
    $cfg = Get-NetIPConfiguration -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue
    $hasGateway = [bool]($cfg -and $cfg.IPv4DefaultGateway)
    $dhcpAddress = (Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -eq 'Dhcp' } | Select-Object -First 1).IPAddress
}
$otherSubnet = [bool](Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { (Test-CableAddress $_.IPAddress) -and (-not $adapter -or $_.InterfaceIndex -ne $adapter.InterfaceIndex) })

# Port 80 yang dipegang Apache aplikasi ini sendiri (pasang ulang / update) tidak dihitung "dipakai program lain".
$ownPids = @(Get-CimInstance Win32_Service -Filter "Name='VerifikasiFaktur'" -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessId })
$ownPids += @(Get-CimInstance Win32_Process -Filter "Name='httpd.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $ownPids -contains $_.ParentProcessId } | ForEach-Object { $_.ProcessId })
$port80Busy = [bool](Get-NetTCPConnection -LocalPort 80 -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $ownPids -notcontains $_.OwningProcess })

$sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
$facts = @{
    Is64Bit = [Environment]::Is64BitOperatingSystem
    WindowsBuild = [Environment]::OSVersion.Version.Build
    SacState = $(if ($null -eq $sac) { 0 } else { [int]$sac })
    FreeBytes = (Get-PSDrive C).Free
    Adapter = $adapter
    AdapterHasGateway = $hasGateway
    AdapterDhcpAddress = $dhcpAddress
    OtherSubnetUse = $otherSubnet
    Port80Busy = $port80Busy
}

$checks = Get-PreflightResult -Role $Role -Facts $facts
$mark = @{ ok = '[OK]'; warn = '[!] '; block = '[X] ' }
$lines = $checks | ForEach-Object { '{0} {1}: {2}' -f $mark[$_.status], $_.name, $_.message }
Write-Utf8NoBom $ResultFile ($lines -join "`r`n")
Write-Utf8NoBom "$ResultFile.adapters" (($wired | ForEach-Object { "$($_.InterfaceIndex)|$($_.Name) ($($_.InterfaceDescription))" }) -join "`r`n")
Write-Utf8NoBom "$ResultFile.adapter" $(if ($adapter) { [string]$adapter.InterfaceIndex } else { '0' })

if ($checks | Where-Object { $_.status -eq 'block' }) { exit 2 }
exit 0
