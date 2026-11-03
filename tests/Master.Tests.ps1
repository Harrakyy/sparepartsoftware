Import-Module (Join-Path $PSScriptRoot '..\scripts\Master.psm1') -Force

Describe 'Get-AppPort' {
    It 'keeps the port of an earlier install' {
        Get-AppPort -Previous 8080 -IsListening { param($p) $false } | Should Be 8080
    }
    It 'uses 80 when it is free' {
        Get-AppPort -IsListening { param($p) $false } | Should Be 80
    }
    It 'falls back to 8080 when 80 is taken' {
        Get-AppPort -IsListening { param($p) $p -eq 80 } | Should Be 8080
    }
}

Describe 'New-EnvContent' {
    $common = @{ DataDir = 'C:\VerifikasiFaktur\data'; BackupDir = 'C:\VerifikasiFaktur\backup'; Url = 'http://localhost:8080' }

    It 'creates a fresh key and pairing code' {
        $content = New-EnvContent @common
        $content | Should Match '(?m)^APP_KEY=base64:[A-Za-z0-9+/]{43}=$'
        $content | Should Match '(?m)^APP_PAIRING_CODE=[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{8}$'
        $content | Should Match '(?m)^APP_EDITION=offline$'
        $content | Should Match "(?m)^DB_DATABASE='C:\\VerifikasiFaktur\\data\\database\.sqlite'$"
        $content | Should Match '(?m)^APP_URL=http://localhost:8080$'
        $content | Should Not Match 'LICENSE_ENFORCE'
    }

    It 'keeps the key, pairing code and custom settings of an existing install' {
        $old = "APP_KEY=base64:LAMA0000000000000000000000000000000000000000=`nAPP_PAIRING_CODE=ABCD2345`nCOMPANY_NAME=PT Mitra`nAPP_URL=http://lama"
        $content = New-EnvContent -Existing $old @common
        $content | Should Match '(?m)^APP_KEY=base64:LAMA0000000000000000000000000000000000000000=$'
        $content | Should Match '(?m)^APP_PAIRING_CODE=ABCD2345$'
        $content | Should Match '(?m)^COMPANY_NAME=PT Mitra$'
        $content | Should Match '(?m)^APP_URL=http://localhost:8080$'
    }
}

Describe 'storage junction' {
    $app = Join-Path $TestDrive 'app'
    $data = Join-Path $TestDrive 'data'
    $tpl = Join-Path $TestDrive 'tpl'
    New-Item -ItemType Directory -Force "$app\public", "$tpl\app\keys", "$tpl\framework\cache" | Out-Null
    Set-Content "$tpl\app\keys\public.key" 'KUNCI-BARU'

    It 'links app\storage to data\storage and refreshes the public key' {
        New-Item -ItemType Directory -Force "$data\storage\app\keys", "$data\storage\app\private" | Out-Null
        Set-Content "$data\storage\app\keys\public.key" 'KUNCI-LAMA'
        Set-Content "$data\storage\app\private\faktur.pdf" 'PDF'

        Set-StorageLink -AppDir $app -DataDir $data -TemplateDir $tpl

        (Get-Item "$app\storage" -Force).Attributes -band [IO.FileAttributes]::ReparsePoint | Should Not Be 0
        Get-Content "$app\storage\app\private\faktur.pdf" | Should Be 'PDF'
        Get-Content "$data\storage\app\keys\public.key" | Should Be 'KUNCI-BARU'
        Test-Path "$data\storage\framework\cache" | Should Be $true
    }

    It 'removes app\ without deleting what the junction points to' {
        Remove-AppDir -AppDir $app

        Test-Path $app | Should Be $false
        Get-Content "$data\storage\app\private\faktur.pdf" | Should Be 'PDF'
    }

    It 'refuses to delete an app\storage that is a real folder' {
        New-Item -ItemType Directory -Force "$TestDrive\app2\storage" | Out-Null
        { Remove-AppDir -AppDir "$TestDrive\app2" } | Should Throw 'junction'
        Test-Path "$TestDrive\app2\storage" | Should Be $true
    }
}

Describe 'Get-InstallInfo' {
    It 'shows the address and pairing code' {
        $info = Get-InstallInfo -Url 'http://192.168.1.10:8080' -PairingCode 'ABCD2345' -NetworkCategory 'Private' -Dhcp $false
        $info | Should Match 'http://192\.168\.1\.10:8080'
        $info | Should Match 'ABCD2345'
        $info | Should Not Match 'PERINGATAN'
    }
    It 'warns about a Public network and a DHCP address' {
        $info = Get-InstallInfo -Url 'http://192.168.1.10' -PairingCode 'ABCD2345' -NetworkCategory 'Public' -Dhcp $true
        ([regex]::Matches($info, 'PERINGATAN')).Count | Should Be 2
    }
}

Describe 'config templates' {
    It 'writes httpd.conf with the port and app public folder' {
        $out = Join-Path $TestDrive 'httpd.conf'
        Write-HttpdConf -Template (Join-Path $PSScriptRoot '..\templates\httpd.conf') -Out $out -ServerRoot 'C:\VF\apache\Apache24' -AppPublic 'C:\VF\app\public' -PhpDir 'C:\VF\php' -Port 8080
        $conf = Get-Content $out -Raw
        $conf | Should Match '(?m)^Listen 8080'
        $conf | Should Match 'DocumentRoot "C:/VF/app/public"'
        $conf | Should Match 'LoadModule php_module "C:/VF/php/php8apache2_4\.dll"'
        $conf | Should Not Match '__'
    }
    It 'writes php.ini with an absolute extension_dir' {
        $out = Join-Path $TestDrive 'php.ini'
        Write-PhpIni -Template (Join-Path $PSScriptRoot '..\templates\php.ini') -Out $out -PhpDir 'C:\VF\php'
        (Get-Content $out -Raw) | Should Match 'extension_dir = "C:\\VF\\php\\ext"'
    }
}
