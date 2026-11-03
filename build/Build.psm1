# Fungsi bantu build installer: unduh paket dengan cek checksum, gerbang versi PHP, dan
# pemeriksaan bahwa file rahasia lisensi tidak ikut dikemas.

Set-StrictMode -Version Latest

function Get-VerifiedFile {
    <#
      Unduh satu paket ke CacheDir (atau pakai salinan cache bila hash cocok) dan pastikan SHA-256-nya
      sama dengan yang dipatok. Url boleh berisi beberapa alamat cadangan (dicoba berurutan bila gagal
      diunduh). Hash beda = langsung gagal: file rusak/dipalsukan tidak pernah dipakai.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Url,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][string]$CacheDir,
        [scriptblock]$Download = { param($Url, $OutFile) Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $OutFile -UserAgent 'Mozilla/5.0' }
    )

    $dir = (New-Item -ItemType Directory -Force -Path $CacheDir).FullName
    $name = ($Url[0] -split '/')[-1]
    $target = Join-Path $dir $name
    if ((Test-Path $target) -and (Get-FileHash $target -Algorithm SHA256).Hash -eq $Sha256.ToUpper()) {
        return $target
    }

    $part = "$target.part"
    $lastError = $null
    foreach ($u in $Url) {
        try {
            Remove-Item $part -Force -ErrorAction SilentlyContinue
            & $Download $u $part
        } catch {
            $lastError = $_
            continue
        }
        $actual = (Get-FileHash $part -Algorithm SHA256).Hash
        if ($actual -ne $Sha256.ToUpper()) {
            Remove-Item $part -Force -ErrorAction SilentlyContinue
            throw "Gagal: checksum $name tidak cocok (dapat $actual, harus $Sha256). Jangan dipakai; periksa versions.psd1 / sumber unduhan."
        }
        Move-Item $part $target -Force
        return $target
    }
    throw "Gagal mengunduh ${name}: $lastError"
}

function Assert-CleanStage {
    # Kunci rahasia lisensi dan file lisensi tidak boleh pernah ada di paket installer.
    param([Parameter(Mandatory)][string]$StageDir)

    $bad = @(Get-ChildItem -Path $StageDir -Recurse -File -Include 'secret.key', 'license.lic' -ErrorAction SilentlyContinue)
    if ($bad.Count -gt 0) {
        throw "Paket berisi file rahasia, build dihentikan: $(($bad | ForEach-Object { $_.FullName }) -join ', ')"
    }
}

function Test-PhpVersion {
    param([Parameter(Mandatory)][string]$Actual, [Parameter(Mandatory)][string]$Minimum)

    return ([version]$Actual) -ge ([version]$Minimum)
}

Export-ModuleMember -Function Get-VerifiedFile, Assert-CleanStage, Test-PhpVersion
