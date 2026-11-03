Import-Module (Join-Path $PSScriptRoot '..\scripts\Common.psm1') -Force

Describe 'Set-RestrictedAcl' {
    $root = Join-Path $TestDrive 'pasang'
    New-Item -ItemType Directory -Force "$root\app\public", "$root\data" | Out-Null
    Set-Content "$root\app\public\index.php" 'halo'
    Set-Content "$root\data\catatan.txt" 'rahasia'

    It 'keeps files readable when users get read access' {
        Set-RestrictedAcl -Path $root -ReadUsers
        Get-Content "$root\app\public\index.php" | Should Be 'halo'
    }

    It 'makes every file inherit from the folder instead of carrying its own entries' {
        $acl = Get-Acl "$root\app\public\index.php"
        @($acl.Access | Where-Object { -not $_.IsInherited }).Count | Should Be 0
        @($acl.Access | Where-Object { $_.IdentityReference -match 'SYSTEM' }).Count | Should BeGreaterThan 0
    }

    It 'removes the users entry from a restricted folder' {
        Set-RestrictedAcl -Path "$root\data"
        $acl = Get-Acl "$root\data"
        $users = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'
        @($acl.Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -eq $users }).Count | Should Be 0
        # Tes jalan sebagai user biasa: isi folder terkunci tak boleh terbaca (berarti izin baru ikut turun ke file).
        { Get-Content "$root\data\catatan.txt" -ErrorAction Stop } | Should Throw
    }

    # Kembalikan izin supaya TestDrive bisa dibersihkan (pemilik selalu boleh mengubah izin).
    & icacls $root /reset /T /C /Q | Out-Null
}
