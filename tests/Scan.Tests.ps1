Import-Module (Join-Path $PSScriptRoot '..\scripts\Scan.psm1') -Force

Describe 'Test-MasterConnection' {
    It 'reports an unreachable master' {
        $r = Test-MasterConnection -Server '192.168.1.10' -PairingCode 'ABCD2345' -Get { param($Url, $Headers) throw 'timeout' }
        $r.ok | Should Be $false
        $r.message | Should Match 'Tidak bisa terhubung ke komputer master di http://192\.168\.1\.10'
    }
    It 'reports a wrong pairing code' {
        $r = Test-MasterConnection -Server 'http://192.168.1.10' -PairingCode 'SALAH' -Get { param($Url, $Headers) if ($Url -like '*/up') { 200 } else { 403 } }
        $r.ok | Should Be $false
        $r.message | Should Be 'Kode pemasangan salah.'
    }
    It 'accepts a master that has no backup yet' {
        $seen = @{}
        $r = Test-MasterConnection -Server 'http://192.168.1.10/' -PairingCode 'ABCD2345' -Get { param($Url, $Headers) $seen.code = $Headers['X-Pairing-Code']; if ($Url -like '*/up') { 200 } else { 404 } }
        $r.ok | Should Be $true
        $seen.code | Should Be 'ABCD2345'
    }
}

Describe 'Invoke-BackupPull' {
    $dir = Join-Path $TestDrive 'backup'
    $state = @{ n = 0 }
    $sqlite = { param($Url, $Headers, $OutFile) [IO.File]::WriteAllBytes($OutFile, [Text.Encoding]::ASCII.GetBytes("SQLite format 3`0isi-$($state.n)")) }
    $pull = { param($Now) Invoke-BackupPull -Server 'http://m' -PairingCode 'ABCD2345' -BackupDir $dir -Download $sqlite -Now $Now }
    $start = [datetime]'2026-11-04 08:00'

    It 'saves an hourly and a daily copy' {
        (& $pull $start).ok | Should Be $true
        @(Get-ChildItem "$dir\perjam" -File).Count | Should Be 1
        @(Get-ChildItem "$dir\harian" -File).Count | Should Be 1
        Test-Path "$dir\perjam\faktur-20261104-0800.sqlite" | Should Be $true
    }

    It 'skips a copy identical to the last one' {
        & $pull $start.AddHours(1) | Out-Null
        @(Get-ChildItem "$dir\perjam" -File).Count | Should Be 1
    }

    It 'keeps 24 hourly and 7 daily copies' {
        for ($i = 1; $i -le 40; $i++) {
            $state.n = $i
            & $pull $start.AddHours($i * 5) | Out-Null   # 5 jam sekali → melewati banyak hari
        }
        @(Get-ChildItem "$dir\perjam" -File).Count | Should Be 24
        @(Get-ChildItem "$dir\harian" -File).Count | Should Be 7
    }

    It 'leaves existing copies untouched when the download fails' {
        $before = @(Get-ChildItem "$dir\perjam" -File).Count
        $r = Invoke-BackupPull -Server 'http://m' -PairingCode 'ABCD2345' -BackupDir $dir -Download { param($Url, $Headers, $OutFile) throw 'putus' } -Now $start.AddDays(30)
        $r.ok | Should Be $false
        @(Get-ChildItem "$dir\perjam" -File).Count | Should Be $before
        @(Get-ChildItem $dir -File -Filter '.tmp-*').Count | Should Be 0
    }

    It 'rejects a response that is not a SQLite database' {
        $r = Invoke-BackupPull -Server 'http://m' -PairingCode 'ABCD2345' -BackupDir $dir -Download { param($Url, $Headers, $OutFile) Set-Content $OutFile '<html>error</html>' } -Now $start.AddDays(31)
        $r.ok | Should Be $false
        $r.message | Should Match 'bukan database'
    }
}

Describe 'Find-MasterUrl' {
    It 'uses port 8080 when the master is not on port 80' {
        $get = { param($Url, $Headers) if ($Url -like 'http://192.168.77.1:8080/*') { if ($Url -like '*/up') { 200 } else { 404 } } else { throw 'tidak menjawab' } }
        $r = Find-MasterUrl -Address '192.168.77.1' -PairingCode 'ABCD2345' -Get $get -WaitSeconds 0
        $r.ok | Should Be $true
        $r.url | Should Be 'http://192.168.77.1:8080'
    }
    It 'prefers port 80' {
        $r = Find-MasterUrl -Address '192.168.77.1' -PairingCode 'ABCD2345' -Get { param($Url, $Headers) if ($Url -like '*/up') { 200 } else { 404 } } -WaitSeconds 0
        $r.url | Should Be 'http://192.168.77.1'
    }
    It 'stops at once on a wrong pairing code' {
        $r = Find-MasterUrl -Address '192.168.77.1' -PairingCode 'SALAH' -Get { param($Url, $Headers) if ($Url -like '*/up') { 200 } else { 403 } } -WaitSeconds 5
        $r.ok | Should Be $false
        $r.message | Should Be 'Kode pemasangan salah.'
    }
    It 'reports an unreachable master by its cable address' {
        $r = Find-MasterUrl -Address '192.168.77.1' -PairingCode 'ABCD2345' -Get { param($Url, $Headers) throw 'tidak menjawab' } -WaitSeconds 0
        $r.ok | Should Be $false
        $r.message | Should Match 'Tidak bisa terhubung ke komputer master di 192\.168\.77\.1'
        $r.message | Should Match 'kabel'
    }
}

Describe 'master readiness' {
    $answer = { param($Status) { param($Url, $Headers) if ($Url -like '*/up') { 200 } else { $Status } }.GetNewClosure() }

    It 'stops at once when the master has no active license' {
        $r = Find-MasterUrl -Address '192.168.77.1' -PairingCode 'ABCD2345' -Get (& $answer 302) -WaitSeconds 5
        $r.ok | Should Be $false
        $r.message | Should Match 'Komputer master belum diaktivasi'
    }
    It 'asks to wait when the checks came too fast' {
        $r = Test-MasterConnection -Server '192.168.77.1' -PairingCode 'ABCD2345' -Get (& $answer 429)
        $r.ok | Should Be $false
        $r.message | Should Match 'tunggu 1 menit'
    }
}
