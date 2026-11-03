# Versi paket yang dibungkus ke installer. Semua dipatok + SHA-256; build menolak bila hash beda.
# Ganti versi = ubah URL + SHA-256 dari sumber resmi (lihat README "Memperbarui versi").
@{
    AppVersion = '1.0.0'
    MinPhp     = '8.3.36'

    Php = @{
        Version = '8.3.36'
        # Rilis yang sudah lewat dipindah ke /archives/, jadi dicoba berurutan.
        Url     = @(
            'https://windows.php.net/downloads/releases/php-8.3.36-1-Win32-vs16-x64.zip',
            'https://windows.php.net/downloads/releases/archives/php-8.3.36-1-Win32-vs16-x64.zip'
        )
        Sha256  = '126DD3CC8C19DF5085B9420B2BC74ED591DE3D98528858C52FC42739B7BBA92E'
    }

    Apache = @{
        Version = '2.4.69'
        Url     = @('https://www.apachelounge.com/download/VS18/binaries/httpd-2.4.69-261002-Win64-VS18.zip')
        Sha256  = '77D715D0D9CEE731E2251E7DDC2090A7A8E6D41FEDEF2E9827CD918593C5A652'
    }

    # Visual C++ 2017–2026 x64 (14.51.36247, ditandatangani Microsoft). URL aka.ms tidak berversi:
    # bila Microsoft memperbaruinya, build gagal checksum → periksa tanda tangan file baru lalu patok ulang.
    VcRedist = @{
        Version = '14.51.36247'
        Url     = @('https://aka.ms/vs/18/release/vc_redist.x64.exe')
        Sha256  = '843068991DAAA1F73AD9F6239BCE4D0F6A07A51F18C37EA2A867E9BECA71295C'
    }
}
