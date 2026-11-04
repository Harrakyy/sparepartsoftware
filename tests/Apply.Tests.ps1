Import-Module (Join-Path $PSScriptRoot '..\scripts\Apply.psm1') -Force

Describe 'ConvertFrom-PowercfgValue' {
    It 'reads the AC value from English output' {
        $out = @(
            'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)',
            '  Subgroup GUID: 238c9fa8-0aad-41ed-83f4-97be242c8f20  (Sleep)',
            '    Power Setting GUID: 29f6c1db-86da-48c5-9fdb-f2b67b1f44da  (Sleep after)',
            '      Minimum Possible Setting: 0x00000000',
            '      Maximum Possible Setting: 0xffffffff',
            '      Possible Settings increment: 0x00000001',
            '      Possible Settings units: Seconds',
            '    Current AC Power Setting Index: 0x00001c20',
            '    Current DC Power Setting Index: 0x00000384'
        )
        ConvertFrom-PowercfgValue $out | Should Be 7200
    }
    It 'reads the AC value from Indonesian output' {
        $out = @(
            'GUID Skema Daya: 381b4222-f694-41f0-9685-ff5bb260df2e  (Seimbang)',
            '    GUID Pengaturan Daya: 5ca83367-6e45-459f-a27b-476b1d01c936  (Tindakan tutup penutup)',
            '      Indeks Pengaturan yang Memungkinkan: 000',
            '    Indeks Pengaturan Daya AC Saat Ini: 0x00000001',
            '    Indeks Pengaturan Daya DC Saat Ini: 0x00000002'
        )
        ConvertFrom-PowercfgValue $out | Should Be 1
    }
    It 'returns nothing when the setting is missing' {
        ConvertFrom-PowercfgValue @('Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)') | Should BeNullOrEmpty
    }
}

Describe 'Get-SchemeGuid' {
    It 'finds the active scheme in any language' {
        Get-SchemeGuid @('GUID Skema Daya: 381b4222-f694-41f0-9685-ff5bb260df2e  (Seimbang)') | Should Be '381b4222-f694-41f0-9685-ff5bb260df2e'
    }
}
