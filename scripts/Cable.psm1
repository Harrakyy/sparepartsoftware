# Logika murni jaringan kabel & pemeriksaan sebelum pasang (diuji Pester dengan data adaptor palsu).
# Penerapannya ke sistem ada di Cable-Apply.ps1 dan preflight.ps1.

Set-StrictMode -Version Latest

$Subnet = '192.168.77'
$VirtualPattern = 'Wi-?Fi|Wireless|WLAN|Bluetooth|VPN|Hyper-V|vEthernet|VMware|VirtualBox|TAP-|WAN Miniport|Loopback'

function Get-CableAddress {
    # Alamat tetap di port LAN: master .1, scan titik 1 .2, titik 2 .3.
    param([Parameter(Mandatory)][ValidateSet('master', 'scan')][string]$Role, [ValidateSet(1, 2)][int]$Point = 1)

    if ($Role -eq 'master') { return "$Subnet.1" }
    return "$Subnet.$($Point + 1)"
}

function Test-CableAddress([string]$Address) {
    return $Address -like "$Subnet.*"
}

function Select-CableAdapter {
    <#
      Port LAN fisik untuk kabel: bukan Wi-Fi/Bluetooth/VPN/virtual. Boleh kabelnya belum tersambung
      (dipilih lewat InterfaceIndex, bukan status Up); bila lebih dari satu, yang tersambung didahulukan.
    #>
    param([AllowEmptyCollection()][object[]]$Adapters)

    $wired = @($Adapters | Where-Object {
        -not $_.Virtual -and ($_.MediaType -eq '802.3' -or $_.PhysicalMediaType -eq '802.3') -and
        "$($_.Name) $($_.InterfaceDescription)" -notmatch $VirtualPattern
    })
    if ($wired.Count -eq 0) { return $null }
    $up = @($wired | Where-Object { $_.Status -eq 'Up' })
    if ($up.Count -gt 0) { return $up[0] }
    return $wired[0]
}

function New-Check([string]$Name, [string]$Status, [string]$Message) {
    return @{ name = $Name; status = $Status; message = $Message }
}

function Get-PreflightResult {
    <#
      Hasil pemeriksaan komputer sebelum pasang: status ok / warn / block per baris. Satu "block" saja
      sudah menahan pemasangan (tidak ada yang diubah). Facts dikumpulkan preflight.ps1 dari sistem.
    #>
    param([Parameter(Mandatory)][ValidateSet('master', 'scan')][string]$Role, [Parameter(Mandatory)][hashtable]$Facts)

    $checks = @()

    $bits = if ($Facts.Is64Bit) { '64-bit' } else { '32-bit' }
    $name = if ([int]$Facts.WindowsBuild -ge 22000) { 'Windows 11' } else { 'Windows 10' }
    if ([int]$Facts.WindowsBuild -lt 10240) {
        $checks += New-Check 'Windows' 'block' 'Butuh Windows 10 atau 11.'
    } elseif ($Role -eq 'master' -and -not $Facts.Is64Bit) {
        $checks += New-Check 'Windows' 'block' "Komputer master butuh Windows 64-bit (ini $name $bits)."
    } else {
        $checks += New-Check 'Windows' 'ok' "$name $bits (build $($Facts.WindowsBuild))"
    }

    if ([int]$Facts.SacState -in 1, 2) {
        $mode = if ([int]$Facts.SacState -eq 1) { 'On' } else { 'Evaluation' }
        $checks += New-Check 'Smart App Control' 'block' ("Smart App Control menyala ($mode): Windows akan memblokir aplikasi ini. " +
            'Matikan di Windows Security > App & browser control > Smart App Control (tidak bisa dinyalakan lagi tanpa reset Windows), atau hubungi Ashira.')
    } else {
        $checks += New-Check 'Smart App Control' 'ok' 'Tidak aktif'
    }

    $need = if ($Role -eq 'master') { 1GB } else { 100MB }
    $free = '{0:N1} GB kosong' -f ([double]$Facts.FreeBytes / 1GB)
    if ([double]$Facts.FreeBytes -lt $need) {
        $checks += New-Check 'Ruang disk' 'block' ("Ruang disk C: kurang ($free, butuh {0})." -f $(if ($Role -eq 'master') { '1 GB' } else { '100 MB' }))
    } else {
        $checks += New-Check 'Ruang disk' 'ok' $free
    }

    $adapter = $Facts.Adapter
    if ($null -eq $adapter) {
        $checks += New-Check 'Port LAN' 'block' 'Port LAN tidak ditemukan. Pasang adaptor USB-LAN lalu klik Periksa lagi.'
    } else {
        $checks += New-Check 'Port LAN' 'ok' "$($adapter.Name) ($($adapter.InterfaceDescription))"
        $dhcp = [string]$Facts.AdapterDhcpAddress
        $office = $Facts.AdapterHasGateway -or ($dhcp -and $dhcp -notlike '169.254.*' -and -not (Test-CableAddress $dhcp))
        if ($office) {
            $checks += New-Check 'Port LAN bebas' 'block' ('Port LAN ini sedang dipakai jaringan kantor/internet (tersambung ke router), jadi alamatnya tidak diubah. ' +
                'Pakai adaptor USB-LAN terpisah untuk kabel ke switch.')
        } else {
            $checks += New-Check 'Port LAN bebas' 'ok' 'Tidak dipakai jaringan lain'
        }
    }

    if ($Facts.OtherSubnetUse) {
        $checks += New-Check 'Alamat kabel' 'block' "Alamat $Subnet.x sudah dipakai jaringan lain di komputer ini; hubungi Ashira untuk memilih alamat lain."
    } else {
        $checks += New-Check 'Alamat kabel' 'ok' "$Subnet.x bebas"
    }

    if ($Role -eq 'master') {
        if ($Facts.Port80Busy) {
            $checks += New-Check 'Port 80' 'warn' 'Port 80 dipakai program lain; aplikasi memakai port 8080 (komputer scan menyesuaikan otomatis).'
        } else {
            $checks += New-Check 'Port 80' 'ok' 'Bebas'
        }
    }

    return $checks
}

function Write-CableState {
    # Konfigurasi port LAN sebelum diubah, untuk dikembalikan saat aplikasi dicopot.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][int]$InterfaceIndex,
        [Parameter(Mandatory)][bool]$DhcpWasEnabled, [Parameter(Mandatory)][string]$Address)

    $state = [ordered]@{ interfaceIndex = $InterfaceIndex; dhcpWasEnabled = $DhcpWasEnabled; address = $Address }
    [IO.File]::WriteAllText($Path, ($state | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}

function Read-CableState([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    return Get-Content $Path -Raw | ConvertFrom-Json
}

Export-ModuleMember -Function Get-CableAddress, Test-CableAddress, Select-CableAdapter, Get-PreflightResult, Write-CableState, Read-CableState
