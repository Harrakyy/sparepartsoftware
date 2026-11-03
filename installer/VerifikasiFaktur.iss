; Installer Verifikasi Faktur — satu Setup.exe untuk komputer master atau komputer scan.
; Dikompilasi oleh build.ps1:  ISCC /DAppVersion=<versi> /DStageDir=<stage> installer\VerifikasiFaktur.iss
; Kerja sistem (layanan, firewall, jadwal, .env) ada di scripts\*.ps1; Pascal di sini hanya halaman & pemanggilan.
;
; Parameter senyap: /ROLE=master|scan  /SERVER=<alamat master>  /CODE=<kode pemasangan>
;                   /ADMINEMAIL=<email> /ADMINNAME=<nama>  /SKIPADMIN=1  /RESTORE=<file backup>

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef StageDir
  #define StageDir "..\stage"
#endif

[Setup]
AppId={{8F3C2A51-6B7E-4D2A-9C4E-1A2B3C4D5E6F}
AppName=Verifikasi Faktur
AppVersion={#AppVersion}
AppVerName=Verifikasi Faktur {#AppVersion}
AppPublisher=Ashira
DefaultDirName=C:\VerifikasiFaktur
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=no
UsePreviousAppDir=no
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\dist
OutputBaseFilename=Verifikasi-Faktur-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Verifikasi Faktur
SetupLogging=yes
CloseApplications=no

[Messages]
ButtonBack=< &Kembali
ButtonNext=&Lanjut >
ButtonInstall=&Pasang
ButtonCancel=Batal
ButtonFinish=&Selesai
ExitSetupTitle=Keluar
ExitSetupMessage=Pemasangan belum selesai. Keluar sekarang?
WelcomeLabel1=Pemasangan Verifikasi Faktur
WelcomeLabel2=Program ini memasang Verifikasi Faktur {#AppVersion} di komputer ini, sebagai komputer master atau komputer scan.
ReadyLabel1=Siap dipasang.
ReadyLabel2a=Klik Pasang untuk mulai.
FinishedHeadingLabel=Pemasangan selesai
FinishedLabelNoIcons=Verifikasi Faktur sudah terpasang.

[Files]
; Komputer master: app + PHP + Apache + template storage.
Source: "{#StageDir}\app\*"; DestDir: "{app}\app"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: IsMaster
Source: "{#StageDir}\php\*"; DestDir: "{app}\php"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: IsMaster
Source: "{#StageDir}\apache\*"; DestDir: "{app}\apache"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: IsMaster
Source: "{#StageDir}\storage-template\*"; DestDir: "{app}\storage-template"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: IsMaster
Source: "{#StageDir}\vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall; Check: IsMaster
Source: "..\templates\httpd.conf"; DestDir: "{app}\templates"; Flags: ignoreversion; Check: IsMaster
Source: "{#StageDir}\build.json"; DestDir: "{app}"; Flags: ignoreversion
; Skrip untuk kedua peran (juga diekstrak ke {tmp} untuk cek koneksi & persiapan update).
Source: "..\scripts\*"; DestDir: "{app}\scripts"; Flags: ignoreversion

[Run]
Filename: "{win}\notepad.exe"; Parameters: """{app}\INFO-PEMASANGAN.txt"""; Description: "Buka info pemasangan (alamat dan kode pemasangan)"; Flags: postinstall skipifsilent nowait; Check: IsMaster and SetupSucceeded
Filename: "{code:GetActivationUrl}"; Description: "Buka halaman aktivasi lisensi"; Flags: postinstall skipifsilent shellexec nowait; Check: IsMaster and SetupSucceeded

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\uninstall.ps1"" -InstallDir ""{app}"""; Flags: runhidden waituntilterminated; RunOnceId: "VerifikasiFakturUninstall"

[Code]
var
  RolePage: TInputOptionWizardPage;
  AdminPage: TInputQueryWizardPage;
  RestorePage: TInputFileWizardPage;
  ScanPage: TInputQueryWizardPage;
  SetupOk: Boolean;

function HasParam(const Name: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if (CompareText(ParamStr(I), '/' + Name) = 0) or (Pos(Uppercase('/' + Name + '='), Uppercase(ParamStr(I))) = 1) then
      Result := True;
end;

function InstallDir: String;
begin
  // Halaman kustom ada sebelum halaman folder (tersembunyi), jadi {app} belum bisa di-expand di sana.
  Result := RemoveBackslashUnlessRoot(WizardDirValue);
end;

function IsMaster: Boolean;
begin
  Result := RolePage.SelectedValueIndex = 0;
end;

function IsUpdate: Boolean;
begin
  Result := FileExists(InstallDir + '\app\artisan') or FileExists(InstallDir + '\data\.env');
end;

function SetupSucceeded: Boolean;
begin
  Result := SetupOk;
end;

function PowerShell: String;
begin
  Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
end;

function RunScript(const Script, Arguments: String; var ResultCode: Integer): Boolean;
begin
  Result := Exec(PowerShell, '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + Script + '" ' + Arguments,
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure ExtractScripts;
begin
  ExtractTemporaryFile('Common.psm1');
  ExtractTemporaryFile('Master.psm1');
  ExtractTemporaryFile('Scan.psm1');
  ExtractTemporaryFile('setup-scan.ps1');
  ExtractTemporaryFile('pre-update.ps1');
end;

function GetActivationUrl(Param: String): String;
var
  Url: AnsiString;
begin
  if LoadStringFromFile(InstallDir + '\data\local-url.txt', Url) then
    Result := Trim(String(Url)) + '/aktivasi'
  else
    Result := 'http://localhost/aktivasi';
end;

procedure InitializeWizard;
var
  Role: String;
begin
  RolePage := CreateInputOptionPage(wpWelcome, 'Peran komputer', 'Komputer ini akan dipakai sebagai apa?',
    'Komputer master menyimpan data dan menjalankan aplikasi (satu saja). Komputer scan membuka aplikasi dari komputer master lewat WiFi.',
    True, False);
  RolePage.Add('Komputer master (server, menyimpan semua data)');
  RolePage.Add('Komputer scan (titik scan, membuka aplikasi dari master)');
  Role := ExpandConstant('{param:ROLE|' + GetPreviousData('Role', 'master') + '}');
  if CompareText(Role, 'scan') = 0 then RolePage.SelectedValueIndex := 1 else RolePage.SelectedValueIndex := 0;

  AdminPage := CreateInputQueryPage(RolePage.ID, 'Akun superadmin', 'Akun pertama untuk mengelola aplikasi',
    'Password diketik di jendela hitam yang muncul di akhir pemasangan (tidak disimpan oleh installer).');
  AdminPage.Add('Nama:', False);
  AdminPage.Add('Email:', False);
  AdminPage.Values[0] := ExpandConstant('{param:ADMINNAME|Superadmin}');
  AdminPage.Values[1] := ExpandConstant('{param:ADMINEMAIL|}');

  RestorePage := CreateInputFilePage(AdminPage.ID, 'Pulihkan data (opsional)', 'Pakai data dari backup lama?',
    'Kosongkan untuk mulai dengan data kosong. Pilih file faktur-*.sqlite (dari flashdisk atau komputer scan) untuk memulihkan.');
  RestorePage.Add('File backup:', 'Database backup (*.sqlite)|*.sqlite', '.sqlite');
  RestorePage.Values[0] := ExpandConstant('{param:RESTORE|}');

  ScanPage := CreateInputQueryPage(RolePage.ID, 'Komputer master', 'Sambungkan ke komputer master',
    'Lihat INFO-PEMASANGAN.txt di komputer master untuk alamat dan kode pemasangan.');
  ScanPage.Add('Alamat komputer master (mis. 192.168.1.10):', False);
  ScanPage.Add('Kode pemasangan:', False);
  ScanPage.Values[0] := ExpandConstant('{param:SERVER|' + GetPreviousData('Server', '') + '}');
  ScanPage.Values[1] := ExpandConstant('{param:CODE|}');
end;

procedure RegisterPreviousData(PreviousDataKey: Integer);
begin
  if IsMaster then SetPreviousData(PreviousDataKey, 'Role', 'master') else SetPreviousData(PreviousDataKey, 'Role', 'scan');
  if not IsMaster then SetPreviousData(PreviousDataKey, 'Server', ScanPage.Values[0]);
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if (PageID = AdminPage.ID) or (PageID = RestorePage.ID) then
    Result := (not IsMaster) or IsUpdate
  else if PageID = ScanPage.ID then
    Result := IsMaster;
end;

function CheckScanConnection: Boolean;
var
  Code: Integer;
  Msg: AnsiString;
  ResultFile: String;
begin
  ExtractScripts;
  ResultFile := ExpandConstant('{tmp}\scan-check.txt');
  DeleteFile(ResultFile);
  RunScript(ExpandConstant('{tmp}\setup-scan.ps1'), '-Server "' + Trim(ScanPage.Values[0]) + '" -PairingCode "' +
    Trim(ScanPage.Values[1]) + '" -CheckOnly -ResultFile "' + ResultFile + '"', Code);
  Result := Code = 0;
  if not Result then begin
    if not LoadStringFromFile(ResultFile, Msg) then Msg := 'Pemeriksaan koneksi gagal dijalankan.';
    SuppressibleMsgBox(String(Msg), mbError, MB_OK, IDOK);
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = AdminPage.ID) and (Pos('@', AdminPage.Values[1]) = 0) then begin
    MsgBox('Isi email superadmin yang valid.', mbError, MB_OK);
    Result := False;
  end else if CurPageID = ScanPage.ID then begin
    if (Trim(ScanPage.Values[0]) = '') or (Trim(ScanPage.Values[1]) = '') then begin
      MsgBox('Isi alamat komputer master dan kode pemasangan.', mbError, MB_OK);
      Result := False;
    end else
      Result := CheckScanConnection;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Result := '';
  // Mode senyap: halaman dilewati, jadi cek koneksi peran scan di sini.
  if (not IsMaster) and WizardSilent and not CheckScanConnection then begin
    Result := 'Tidak bisa terhubung ke komputer master atau kode pemasangan salah.';
    exit;
  end;
  if IsMaster and FileExists(InstallDir + '\app\artisan') then begin
    ExtractScripts;
    RunScript(ExpandConstant('{tmp}\pre-update.ps1'), '-InstallDir "' + InstallDir + '"', Code);
    if Code <> 0 then
      Result := 'Persiapan update gagal (backup sebelum-update tidak berhasil), jadi update dibatalkan dan data tidak diubah. ' +
        'Lihat ' + InstallDir + '\data\install.log';
  end;
end;

procedure CreateSuperadmin;
var
  Code, Attempt: Integer;
  Php, Artisan: String;
begin
  Php := InstallDir + '\php\php.exe';
  Artisan := InstallDir + '\app\artisan';
  for Attempt := 1 to 3 do begin
    // Jendela konsol php: superadmin mengetik password di sana (installer tidak pernah melihatnya).
    Exec(Php, '"' + Artisan + '" app:superadmin "' + Trim(AdminPage.Values[1]) + '" --name="' + Trim(AdminPage.Values[0]) + '"',
      InstallDir + '\app', SW_SHOW, ewWaitUntilTerminated, Code);
    if Code = 0 then begin
      MsgBox('Akun superadmin ' + Trim(AdminPage.Values[1]) + ' dibuat.', mbInformation, MB_OK);
      exit;
    end;
    if MsgBox('Akun superadmin belum berhasil dibuat (password tidak sama / kurang dari 8 karakter, atau email sudah terdaftar). Coba lagi?',
      mbConfirmation, MB_YESNO) = IDNO then exit;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Code: Integer;
  Args: String;
  FreshInstall: Boolean;
begin
  if CurStep <> ssPostInstall then exit;
  WizardForm.StatusLabel.Caption := 'Menyiapkan aplikasi (layanan, database, jadwal)...';
  if IsMaster then begin
    FreshInstall := not FileExists(InstallDir + '\data\install.json');
    Args := '-InstallDir "' + InstallDir + '" -VcRedist "' + ExpandConstant('{tmp}\vc_redist.x64.exe') + '"';
    if FreshInstall and (Trim(RestorePage.Values[0]) <> '') then
      Args := Args + ' -RestoreFrom "' + Trim(RestorePage.Values[0]) + '"';
    RunScript(InstallDir + '\scripts\setup-master.ps1', Args, Code);
    if Code <> 0 then
      RaiseException('Menyiapkan komputer master gagal. Lihat ' + InstallDir + '\data\install.log');
    if FreshInstall and (not HasParam('SKIPADMIN')) and (not WizardSilent) then CreateSuperadmin;
  end else begin
    RunScript(InstallDir + '\scripts\setup-scan.ps1', '-InstallDir "' + InstallDir + '" -Server "' + Trim(ScanPage.Values[0]) +
      '" -PairingCode "' + Trim(ScanPage.Values[1]) + '"', Code);
    if Code <> 0 then
      RaiseException('Menyiapkan komputer scan gagal. Lihat ' + InstallDir + '\install.log');
  end;
  SetupOk := True;
end;
