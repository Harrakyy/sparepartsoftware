Import-Module (Join-Path $PSScriptRoot '..\build\Build.psm1') -Force

Describe 'Get-VerifiedFile' {
    $fake = { param($Url, $OutFile) Set-Content -Path $OutFile -Value 'isi paket' -NoNewline }
    $goodSha = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('isi paket'))) -Algorithm SHA256).Hash

    It 'returns the cached path when the checksum matches' {
        $path = Get-VerifiedFile -Url 'https://contoh.test/paket.zip' -Sha256 $goodSha -CacheDir "TestDrive:\cache1" -Download $fake
        Test-Path $path | Should Be $true
        (Split-Path $path -Leaf) | Should Be 'paket.zip'
    }

    It 'refuses a file whose checksum does not match and leaves nothing behind' {
        { Get-VerifiedFile -Url 'https://contoh.test/paket.zip' -Sha256 ('0' * 64) -CacheDir "TestDrive:\cache2" -Download $fake } | Should Throw 'checksum'
        @(Get-ChildItem "TestDrive:\cache2" -File -ErrorAction SilentlyContinue).Count | Should Be 0
    }

    It 'falls back to the next URL when a download fails' {
        $flaky = { param($Url, $OutFile) if ($Url -like '*releases*') { throw 'tidak ditemukan' }; Set-Content -Path $OutFile -Value 'isi paket' -NoNewline }
        $path = Get-VerifiedFile -Url @('https://contoh.test/releases/paket.zip', 'https://contoh.test/archives/paket.zip') -Sha256 $goodSha -CacheDir "TestDrive:\cache3" -Download $flaky
        Test-Path $path | Should Be $true
    }
}

Describe 'Assert-CleanStage' {
    It 'refuses a stage that contains the license secret key' {
        New-Item -ItemType File -Force -Path "TestDrive:\kotor\app\storage\app\keys\secret.key" | Out-Null
        { Assert-CleanStage -StageDir "TestDrive:\kotor" } | Should Throw 'secret.key'
    }

    It 'refuses a stage that contains a license file' {
        New-Item -ItemType File -Force -Path "TestDrive:\kotor2\storage-template\app\license.lic" | Out-Null
        { Assert-CleanStage -StageDir "TestDrive:\kotor2" } | Should Throw 'license.lic'
    }

    It 'accepts a clean stage with only the public key' {
        New-Item -ItemType File -Force -Path "TestDrive:\bersih\storage-template\app\keys\public.key" | Out-Null
        { Assert-CleanStage -StageDir "TestDrive:\bersih" } | Should Not Throw
    }
}

Describe 'Test-PhpVersion' {
    It 'rejects versions below the minimum' { Test-PhpVersion -Actual '8.3.35' -Minimum '8.3.36' | Should Be $false }
    It 'accepts the minimum' { Test-PhpVersion -Actual '8.3.36' -Minimum '8.3.36' | Should Be $true }
    It 'accepts newer versions' { Test-PhpVersion -Actual '8.4.0' -Minimum '8.3.36' | Should Be $true }
}
