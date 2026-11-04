<#
  Uji beban dua titik scan: dua klien (dua sesi login terpisah) men-scan barang yang SAMA bersamaan.
  Lulus (exit 0) hanya bila total ter-scan tepat = Qty (tidak dobel, tidak melebihi), tidak ada jawaban
  5xx, dan tidak ada "database is locked".
    .\Uji-Beban.ps1 -BaseUrl http://127.0.0.1:8099 -Username bos -Password rahasia123
  Faktur uji dibuat lalu dihapus lagi (butuh akun superadmin).
#>
param(
    [Parameter(Mandatory)][string]$BaseUrl,
    [Parameter(Mandatory)][string]$Username,
    [Parameter(Mandatory)][string]$Password,
    [int]$Qty = 20,
    [int]$PerClient = 20
)

$ErrorActionPreference = 'Stop'
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$work = Join-Path $env:TEMP "uji-beban-$(Get-Random)"
New-Item -ItemType Directory $work | Out-Null

function New-Session([string]$Name) {
    $jar = Join-Path $work "$Name.cookies"
    $html = & $curl -s -c $jar -b $jar "$BaseUrl/login"
    $token = [regex]::Match(($html -join "`n"), 'name="_token" value="([^"]+)"').Groups[1].Value
    $code = & $curl -s -o NUL -w '%{http_code}' -c $jar -b $jar --data-urlencode "_token=$token" `
        --data-urlencode "username=$Username" --data-urlencode "password=$Password" "$BaseUrl/login"
    $page = & $curl -s -c $jar -b $jar "$BaseUrl/gudang"
    $csrf = [regex]::Match(($page -join "`n"), 'name="csrf-token" content="([^"]+)"').Groups[1].Value
    if ($code -ne '302' -or -not $csrf) { throw "Login $Name gagal (HTTP $code). Periksa username/password." }
    return @{ jar = $jar; csrf = $csrf }
}

$a = New-Session 'a'
$b = New-Session 'b'

# Faktur uji: 1 barang UJI-BEBAN sejumlah Qty, file PNG 1x1.
$png = Join-Path $work 'uji.png'
[IO.File]::WriteAllBytes($png, [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='))
$number = '9' + (Get-Random -Minimum 10000000 -Maximum 99999999)
$created = & $curl -s -b $a.jar -H "X-CSRF-TOKEN: $($a.csrf)" -H 'Accept: application/json' `
    -F "file=@$png;type=image/png" -F "number=$number" -F 'customer_name=Uji beban' -F 'source_type=photo' `
    -F 'items[0][code]=UJI-BEBAN' -F 'items[0][name]=Barang uji beban' -F "items[0][qty]=$Qty" "$BaseUrl/api/invoices" | ConvertFrom-Json
if (-not $created.success) { throw "Membuat faktur uji gagal: $($created.error)" }
$id = $created.data.id
Write-Host "Faktur uji $number (id $id), qty $Qty; dua klien x $PerClient scan bersamaan..."

$scanJob = {
    param($curl, $url, $jar, $csrf, $count, $out)
    for ($i = 0; $i -lt $count; $i++) {
        # Field form, bukan JSON: PowerShell 5.1 membuang tanda kutip JSON saat diteruskan ke curl.exe.
        $code = & $curl -s -o "$out-$i.json" -w '%{http_code}' -b $jar -H "X-CSRF-TOKEN: $csrf" -H 'Accept: application/json' `
            -d 'code=UJI-BEBAN' -d 'stage=pick' $url
        Add-Content "$out.codes" $code
    }
}
$url = "$BaseUrl/api/invoices/$id/scans"
$jobs = @(
    Start-Job $scanJob -ArgumentList $curl, $url, $a.jar, $a.csrf, $PerClient, (Join-Path $work 'a')
    Start-Job $scanJob -ArgumentList $curl, $url, $b.jar, $b.csrf, $PerClient, (Join-Path $work 'b')
)
$jobs | Wait-Job | Receive-Job
$jobs | Remove-Job

$codes = @(Get-Content (Join-Path $work 'a.codes')) + @(Get-Content (Join-Path $work 'b.codes'))
$files = Get-ChildItem $work -Filter '*-*.json'
$bodies = ($files | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
# Scan yang melebihi qty dijawab 200 dengan result "over_qty" (dicatat, tidak menambah hitungan).
$results = $files | ForEach-Object { try { (Get-Content $_.FullName -Raw | ConvertFrom-Json).data.scan.result } catch { 'tak-terbaca' } }
$detail = & $curl -s -b $a.jar -H 'Accept: application/json' "$BaseUrl/api/invoices/$id" | ConvertFrom-Json
$picked = ($detail.data.items | Measure-Object picked_qty -Sum).Sum

& $curl -s -o NUL -X DELETE -b $a.jar -H "X-CSRF-TOKEN: $($a.csrf)" -H 'Accept: application/json' "$BaseUrl/api/invoices/$id"
Remove-Item $work -Recurse -Force

$ok = @($results | Where-Object { $_ -eq 'ok' }).Count
$rejected = @($results | Where-Object { $_ -eq 'over_qty' }).Count
$errors = @($codes | Where-Object { [int]$_ -ge 500 }).Count
$locked = $bodies -match 'database is locked'
Write-Host ("Hasil: berhasil {0}, ditolak (sudah lengkap) {1}, galat 5xx {2}, total ter-scan {3}/{4}{5}" -f $ok, $rejected, $errors, $picked, $Qty, $(if ($locked) { ', ADA "database is locked"' } else { '' }))

if ($picked -ne $Qty -or $errors -gt 0 -or $locked -or $ok -ne $Qty) {
    Write-Host 'GAGAL: dua titik scan bersamaan menghasilkan hitungan salah atau galat.' -ForegroundColor Red
    exit 1
}
Write-Host 'LULUS: dua titik scan bersamaan aman.' -ForegroundColor Green
exit 0
