# Penerapan ke sistem (butuh admin): alamat tetap di port LAN, aturan firewall kabel, dan "jangan sleep".
# Setiap perubahan mencatat keadaan semula supaya bisa dikembalikan persis saat aplikasi dicopot.

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Cable.psm1')

$CableRule = 'Verifikasi Faktur (kabel)'

function Set-CableAddress {
    <#
      Port LAN → alamat tetap /24 tanpa gateway & DNS. Keadaan semula (DHCP nyala?) disimpan sekali ke
      StateFile. Windows melaporkan alamat ganda → dikembalikan dan dilempar galat yang jelas.
    #>
    param([Parameter(Mandatory)][int]$InterfaceIndex, [Parameter(Mandatory)][string]$Address, [Parameter(Mandatory)][string]$StateFile)

    $iface = Get-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4
    if (-not (Test-Path $StateFile)) {
        Write-CableState -Path $StateFile -InterfaceIndex $InterfaceIndex -DhcpWasEnabled ($iface.Dhcp -eq 'Enabled') -Address $Address
    }

    # netsh, bukan New-NetIPAddress: pada port yang kabelnya belum dicolok, Set-NetIPInterface -Dhcp Disabled
    # hanya berlaku di sesi aktif, sehingga New-NetIPAddress gagal menulis ke penyimpanan permanen
    # ("Inconsistent parameters PolicyStore PersistentStore and Dhcp Enabled") dan alamat hilang setelah restart.
    Invoke-Netsh interface ipv4 set address "name=$InterfaceIndex" source=static "address=$Address" mask=255.255.255.0 gateway=none
    Invoke-Netsh interface ipv4 set dnsservers "name=$InterfaceIndex" source=static address=none register=none validate=no

    for ($i = 0; $i -lt 10; $i++) {
        $state = (Get-NetIPAddress -InterfaceIndex $InterfaceIndex -IPAddress $Address -ErrorAction SilentlyContinue).AddressState
        if ($state -eq 'Duplicate') {
            Restore-CableAddress -StateFile $StateFile
            throw "Alamat $Address sudah dipakai komputer lain di kabel ini."
        }
        if ($state -ne 'Tentative') { return }
        Start-Sleep -Seconds 1
    }
}

function Restore-CableAddress {
    # Kembalikan port LAN seperti sebelum dipasang (biasanya: alamat otomatis/DHCP).
    param([Parameter(Mandatory)][string]$StateFile)

    $s = Read-CableState -Path $StateFile
    if (-not $s) { return }
    if (-not (Get-NetAdapter -InterfaceIndex $s.interfaceIndex -ErrorAction SilentlyContinue)) {
        Remove-Item $StateFile -Force  # adaptor (mis. USB-LAN) sudah dicabut: tak ada yang perlu dikembalikan
        return
    }
    # Hapus alamat kabel dari setelan tersimpan dulu. Pada port tanpa kabel, Windows tetap melaporkan
    # "DHCP is already enabled" walau setelan tersimpannya statis, jadi pesan itu dianggap berhasil.
    Invoke-Netsh interface ipv4 delete address "name=$($s.interfaceIndex)" "address=$($s.address)" -Allow 'not found|tidak ditemukan|Element not found'
    if ($s.dhcpWasEnabled) {
        Invoke-Netsh interface ipv4 set address "name=$($s.interfaceIndex)" source=dhcp -Allow 'already enabled|sudah'
        Invoke-Netsh interface ipv4 set dnsservers "name=$($s.interfaceIndex)" source=dhcp -Allow 'already|sudah'
    }
    Remove-Item $StateFile -Force
}

function Invoke-Netsh {
    # -Allow: pola pesan netsh yang berarti "sudah begitu" (bukan galat sungguhan).
    # PositionalBinding=$false: tanpa ini kata kedua ("ipv4") terikat ke -Allow dan perintah netsh kacau.
    [CmdletBinding(PositionalBinding = $false)]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments, [string]$Allow)

    $out = (& netsh @Arguments 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -and -not ($Allow -and $out -match $Allow)) {
        throw "netsh $($Arguments -join ' ') gagal: $out"
    }
}

function Set-CableFirewallRule {
    # Kabel langsung/switch tanpa router = "Unidentified network" (Public, kembali Public tiap restart):
    # izinkan port app hanya dari 192.168.77.x, di semua profil.
    param([Parameter(Mandatory)][int]$Port)

    Remove-CableFirewallRule
    New-NetFirewallRule -DisplayName $CableRule -Direction Inbound -Protocol TCP -LocalPort $Port `
        -RemoteAddress '192.168.77.0/24' -Profile Any -Action Allow | Out-Null
}

function Remove-CableFirewallRule {
    Get-NetFirewallRule -DisplayName $CableRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
}

function ConvertFrom-PowercfgValue([string[]]$Lines) {
    # Keluaran powercfg berbahasa sesuai Windows; dua angka 0x terakhir selalu nilai AC lalu DC.
    $hex = @(($Lines -join "`n") | Select-String -Pattern '0x[0-9a-fA-F]+' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value })
    if ($hex.Count -lt 2) { return $null }  # setelan tak ada: hanya baris GUID skema, tanpa angka 0x
    return [Convert]::ToInt32($hex[-2], 16)
}

function Get-SchemeGuid([string[]]$Lines) {
    $m = [regex]::Match(($Lines -join "`n"), '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}')
    if ($m.Success) { return $m.Value }
    return $null
}

function Get-PowerValue([string]$Scheme, [string]$Sub, [string]$Setting) {
    # /qh: termasuk setelan tersembunyi (mis. tutup layar di sebagian laptop).
    return ConvertFrom-PowercfgValue @(powercfg /qh $Scheme $Sub $Setting 2>$null)
}

$PowerSettings = @(
    @{ key = 'standby'; sub = 'SUB_SLEEP'; setting = 'STANDBYIDLE' },
    @{ key = 'hibernate'; sub = 'SUB_SLEEP'; setting = 'HIBERNATEIDLE' },
    # Alias LIDACTION tidak dikenali di sebagian Windows: pakai GUID resminya (SUB_BUTTONS / tutup layar).
    @{ key = 'lid'; sub = '4f971e89-eebd-4455-a8de-9e59040e7347'; setting = '5ca83367-6e45-459f-a27b-476b1d01c936' }
)

function Set-KeepAwake {
    # Saat dicolok listrik: tidak sleep, tidak hibernate, tutup layar = diam. Nilai lama disimpan sekali.
    param([Parameter(Mandatory)][string]$StateFile)

    if (-not (Test-Path $StateFile)) {
        $scheme = Get-SchemeGuid @(powercfg /getactivescheme)
        if (-not $scheme) { throw 'Skema daya aktif tidak terbaca (powercfg /getactivescheme).' }
        $old = [ordered]@{ scheme = $scheme }
        foreach ($p in $PowerSettings) { $old[$p.key] = Get-PowerValue $scheme $p.sub $p.setting }
        [IO.File]::WriteAllText($StateFile, ($old | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    }
    $scheme = (Get-Content $StateFile -Raw | ConvertFrom-Json).scheme
    foreach ($p in $PowerSettings) { powercfg /setacvalueindex $scheme $p.sub $p.setting 0 2>$null | Out-Null }
    powercfg /setactive $scheme | Out-Null
}

function Restore-KeepAwake {
    param([Parameter(Mandatory)][string]$StateFile)

    if (-not (Test-Path $StateFile)) { return }
    $old = Get-Content $StateFile -Raw | ConvertFrom-Json
    # Kembalikan ke skema yang diubah saat pasang (bukan skema yang kebetulan aktif sekarang).
    $scheme = if ($old.PSObject.Properties['scheme'] -and $old.scheme) { $old.scheme } else { 'SCHEME_CURRENT' }
    foreach ($p in $PowerSettings) {
        $value = $old.($p.key)
        if ($null -ne $value) { powercfg /setacvalueindex $scheme $p.sub $p.setting $value 2>$null | Out-Null }
    }
    powercfg /setactive SCHEME_CURRENT | Out-Null
    Remove-Item $StateFile -Force
}

Export-ModuleMember -Function Set-CableAddress, Restore-CableAddress, Set-CableFirewallRule, Remove-CableFirewallRule, Set-KeepAwake, Restore-KeepAwake, ConvertFrom-PowercfgValue, Get-SchemeGuid
