Import-Module (Join-Path $PSScriptRoot '..\scripts\Cable.psm1') -Force

function New-Adapter([int]$Index, [string]$Name, [string]$Desc, [string]$Status = 'Disconnected', [bool]$Virtual = $false, [string]$Media = '802.3') {
    [pscustomobject]@{ InterfaceIndex = $Index; Name = $Name; InterfaceDescription = $Desc; Status = $Status; Virtual = $Virtual; MediaType = $Media; PhysicalMediaType = $Media }
}

function New-Facts([hashtable]$Override = @{}) {
    $f = @{
        Is64Bit = $true; WindowsBuild = 22631; SacState = 0; FreeBytes = 50GB
        Adapter = (New-Adapter 7 'Ethernet' 'Realtek PCIe GbE'); AdapterHasGateway = $false; AdapterDhcpAddress = $null
        OtherSubnetUse = $false; Port80Busy = $false
    }
    foreach ($k in $Override.Keys) { $f[$k] = $Override[$k] }
    $f
}

function Get-Status($Results, [string]$Name) { ($Results | Where-Object { $_.name -eq $Name }).status }

Describe 'Get-CableAddress' {
    It 'gives the master .1 and the scan points .2 and .3' {
        Get-CableAddress -Role master | Should Be '192.168.77.1'
        Get-CableAddress -Role scan -Point 1 | Should Be '192.168.77.2'
        Get-CableAddress -Role scan -Point 2 | Should Be '192.168.77.3'
    }
}

Describe 'Select-CableAdapter' {
    It 'picks the wired port over Wi-Fi' {
        $a = Select-CableAdapter @((New-Adapter 3 'Wi-Fi' 'Intel Wi-Fi 6' 'Up' $false 'Native 802.11'), (New-Adapter 7 'Ethernet' 'Realtek PCIe GbE'))
        $a.InterfaceIndex | Should Be 7
    }
    It 'ignores virtual adapters and keeps a USB LAN adapter' {
        $a = Select-CableAdapter @((New-Adapter 9 'vEthernet (Default Switch)' 'Hyper-V Virtual Ethernet Adapter' 'Up' $true), (New-Adapter 12 'Ethernet 2' 'ASIX USB 3.0 to Gigabit Ethernet'))
        $a.InterfaceIndex | Should Be 12
    }
    It 'prefers the port whose cable is plugged in' {
        $a = Select-CableAdapter @((New-Adapter 7 'Ethernet' 'Realtek PCIe GbE'), (New-Adapter 12 'Ethernet 2' 'ASIX USB Ethernet' 'Up'))
        $a.InterfaceIndex | Should Be 12
    }
    It 'returns nothing when there is no wired port' {
        Select-CableAdapter @((New-Adapter 3 'Wi-Fi' 'Intel Wi-Fi 6' 'Up' $false 'Native 802.11'), (New-Adapter 20 'VPN' 'TAP-Windows Adapter V9')) | Should BeNullOrEmpty
    }
}

Describe 'Get-PreflightResult' {
    It 'passes a ready master' {
        $r = Get-PreflightResult -Role master -Facts (New-Facts)
        @($r | Where-Object { $_.status -eq 'block' }).Count | Should Be 0
    }
    It 'blocks a 32-bit master but allows a 32-bit scan computer' {
        Get-Status (Get-PreflightResult -Role master -Facts (New-Facts @{ Is64Bit = $false })) 'Windows' | Should Be 'block'
        Get-Status (Get-PreflightResult -Role scan -Facts (New-Facts @{ Is64Bit = $false; WindowsBuild = 19045 })) 'Windows' | Should Be 'ok'
    }
    It 'blocks when Smart App Control is on or evaluating' {
        foreach ($state in 1, 2) {
            $r = Get-PreflightResult -Role master -Facts (New-Facts @{ SacState = $state })
            Get-Status $r 'Smart App Control' | Should Be 'block'
            ($r | Where-Object { $_.name -eq 'Smart App Control' }).message | Should Match 'Smart App Control'
        }
    }
    It 'needs 1 GB on the master and 100 MB on a scan computer' {
        Get-Status (Get-PreflightResult -Role master -Facts (New-Facts @{ FreeBytes = 500MB })) 'Ruang disk' | Should Be 'block'
        Get-Status (Get-PreflightResult -Role scan -Facts (New-Facts @{ FreeBytes = 200MB })) 'Ruang disk' | Should Be 'ok'
    }
    It 'blocks when there is no wired port' {
        $r = Get-PreflightResult -Role scan -Facts (New-Facts @{ Adapter = $null })
        ($r | Where-Object { $_.name -eq 'Port LAN' }).message | Should Match 'Port LAN tidak ditemukan'
        Get-Status $r 'Port LAN' | Should Be 'block'
    }
    It 'never takes over a port that the office network uses' {
        foreach ($role in 'master', 'scan') {
            $gw = Get-PreflightResult -Role $role -Facts (New-Facts @{ AdapterHasGateway = $true })
            Get-Status $gw 'Port LAN bebas' | Should Be 'block'
            ($gw | Where-Object { $_.name -eq 'Port LAN bebas' }).message | Should Match 'USB-LAN'
            Get-Status (Get-PreflightResult -Role $role -Facts (New-Facts @{ AdapterDhcpAddress = '192.168.1.20' })) 'Port LAN bebas' | Should Be 'block'
        }
    }
    It 'accepts a port that only has an automatic 169.254 address' {
        Get-Status (Get-PreflightResult -Role master -Facts (New-Facts @{ AdapterDhcpAddress = '169.254.10.20' })) 'Port LAN bebas' | Should Be 'ok'
    }
    It 'blocks when another adapter already uses 192.168.77.x' {
        Get-Status (Get-PreflightResult -Role master -Facts (New-Facts @{ OtherSubnetUse = $true })) 'Alamat kabel' | Should Be 'block'
    }
    It 'warns the master about a busy port 80 and says nothing to a scan computer' {
        Get-Status (Get-PreflightResult -Role master -Facts (New-Facts @{ Port80Busy = $true })) 'Port 80' | Should Be 'warn'
        @(Get-PreflightResult -Role scan -Facts (New-Facts @{ Port80Busy = $true }) | Where-Object { $_.name -eq 'Port 80' }).Count | Should Be 0
    }
}

Describe 'cable state file' {
    It 'round-trips what is needed to restore the port' {
        $path = Join-Path $TestDrive 'cable.json'
        Write-CableState -Path $path -InterfaceIndex 7 -DhcpWasEnabled $true -Address '192.168.77.1'
        $s = Read-CableState -Path $path
        $s.interfaceIndex | Should Be 7
        $s.dhcpWasEnabled | Should Be $true
        $s.address | Should Be '192.168.77.1'
    }
    It 'returns nothing when there is no state file' {
        Read-CableState -Path (Join-Path $TestDrive 'tidak-ada.json') | Should BeNullOrEmpty
    }
}

Describe 'Get-PreflightResult without cable' {
    It 'does not check the LAN port when the install does not use the cable' {
        foreach ($role in 'master', 'scan') {
            $r = Get-PreflightResult -Role $role -Cable $false -Facts (New-Facts @{ Adapter = $null; AdapterHasGateway = $true; OtherSubnetUse = $true })
            @($r | Where-Object { $_.status -eq 'block' }).Count | Should Be 0
            @($r | Where-Object { $_.name -in 'Port LAN', 'Port LAN bebas', 'Alamat kabel' }).Count | Should Be 0
        }
    }
    It 'still blocks Smart App Control and a 32-bit master without cable' {
        $r = Get-PreflightResult -Role master -Cable $false -Facts (New-Facts @{ SacState = 1; Is64Bit = $false })
        Get-Status $r 'Smart App Control' | Should Be 'block'
        Get-Status $r 'Windows' | Should Be 'block'
    }
}

Describe 'Get-PreflightResult cable link' {
    It 'stops a scan computer whose cable is not plugged in' {
        $r = Get-PreflightResult -Role scan -Facts (New-Facts)
        Get-Status $r 'Kabel LAN' | Should Be 'block'
        ($r | Where-Object { $_.name -eq 'Kabel LAN' }).message | Should Match 'Kabel LAN belum tersambung'
    }
    It 'passes a scan computer with the cable plugged in' {
        $r = Get-PreflightResult -Role scan -Facts (New-Facts @{ Adapter = (New-Adapter 7 'Ethernet' 'Realtek PCIe GbE' 'Up') })
        Get-Status $r 'Kabel LAN' | Should Be 'ok'
    }
    It 'only warns the master, which may be wired after installing' {
        Get-Status (Get-PreflightResult -Role master -Facts (New-Facts)) 'Kabel LAN' | Should Be 'warn'
    }
}
