; Installer Verifikasi Faktur — satu Setup.exe untuk komputer master atau komputer scan.
; Dikompilasi oleh build.ps1:  ISCC /DAppVersion=<versi> /DStageDir=<stage> installer\VerifikasiFaktur.iss
; Kerja sistem (layanan, firewall, jadwal, .env, port LAN) ada di scripts\*.ps1; Pascal di sini hanya
; halaman & pemanggilan. Akun superadmin dibuat di halaman web setelah aktivasi lisensi.
;
; Parameter senyap: /ROLE=master|scan  /CABLE=1|0 (default 1)  /POINT=1|2  /CODE=<kode pemasangan>
;                   /SERVER=<alamat master, hanya tanpa kabel>  /PORT=<n>  /KEEPAWAKE=1|0 (default 1)
;                   /ADAPTER=<InterfaceIndex port LAN>  /RESTORE=<file backup>

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
; Komputer scan boleh Windows 32-bit; komputer master ditahan halaman pemeriksaan bila bukan 64-bit.
ArchitecturesAllowed=x86compatible x64compatible
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
; Skrip untuk kedua peran (juga diekstrak ke {tmp} untuk pemeriksaan, cek koneksi & persiapan update).
Source: "..\scripts\*"; DestDir: "{app}\scripts"; Flags: ignoreversion

[Run]
Filename: "{win}\notepad.exe"; Parameters: """{app}\INFO-PEMASANGAN.txt"""; Description: "Buka info pemasangan (alamat dan kode pemasangan)"; Flags: postinstall skipifsilent nowait; Check: IsMaster and SetupSucceeded
Filename: "{code:GetActivationUrl}"; Description: "Buka halaman aktivasi lisensi"; Flags: postinstall skipifsilent shellexec nowait; Check: IsMaster and SetupSucceeded

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\uninstall.ps1"" -InstallDir ""{app}"""; Flags: runhidden waituntilterminated; RunOnceId: "VerifikasiFakturUninstall"

[Code]
var
  RolePage: TInputOptionWizardPage;
  CheckPage: TWizardPage;
  CheckMemo: TNewMemo;
  CheckAgain: TNewButton;
  AdapterLabel: TNewStaticText;
  AdapterBox: TNewComboBox;
  AdapterIndexes: TStringList;
  CheckBlocked: Boolean;
  MasterPage: TInputOptionWizardPage;
  RestorePage: TInputFileWizardPage;
  PointPage: TInputOptionWizardPage;
  ServerPage: TInputQueryWizardPage;
  CodePage: TInputQueryWizardPage;
  SetupOk: Boolean;

{ ---------- bantuan ---------- }

function ParamValue(const Name, Default: String): String;
begin
  Result := ExpandConstant('{param:' + Name + '|' + Default + '}');
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

function UseCable: Boolean;
begin
  if IsMaster then Result := MasterPage.Values[0] else Result := PointPage.SelectedValueIndex < 2;
end;

function ScanPoint: String;
begin
  if PointPage.SelectedValueIndex = 1 then Result := '2' else Result := '1';
end;

function SelectedAdapter: String;
begin
  Result := '0';
  if (AdapterIndexes <> nil) and (AdapterBox.ItemIndex >= 0) and (AdapterBox.ItemIndex < AdapterIndexes.Count) then
    Result := AdapterIndexes[AdapterBox.ItemIndex];
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
  ExtractTemporaryFile('Cable.psm1');
  ExtractTemporaryFile('Apply.psm1');
  ExtractTemporaryFile('preflight.ps1');
  ExtractTemporaryFile('setup-scan.ps1');
  ExtractTemporaryFile('pre-update.ps1');
end;

function ReadText(const Path: String): String;
var
  S: AnsiString;
begin
  if LoadStringFromFile(Path, S) then Result := Trim(String(S)) else Result := '';
end;

function GetActivationUrl(Param: String): String;
var
  Url: String;
begin
  Url := ReadText(InstallDir + '\data\local-url.txt');
  if Url = '' then Url := 'http://localhost';
  Result := Url + '/aktivasi';
end;

{ ---------- pemeriksaan komputer ---------- }

function RoleName: String;
begin
  if IsMaster then Result := 'master' else Result := 'scan';
end;

function NoCableArg: String;
begin
  if UseCable then Result := '' else Result := ' -NoCable';
end;

procedure RunPreflight;
var
  Code, I, Sep: Integer;
  ResultFile, Adapters, Line, Keep: String;
  Lines: TStringList;
begin
  ExtractScripts;
  Keep := SelectedAdapter;
  if WizardSilent then Keep := ParamValue('ADAPTER', Keep);
  ResultFile := ExpandConstant('{tmp}\preflight.txt');
  RunScript(ExpandConstant('{tmp}\preflight.ps1'), '-Role ' + RoleName + ' -ResultFile "' + ResultFile + '" -AdapterIndex ' + Keep + NoCableArg, Code);
  CheckBlocked := Code <> 0;
  CheckMemo.Text := ReadText(ResultFile);
  if CheckMemo.Text = '' then begin
    CheckMemo.Text := '[X] Pemeriksaan gagal dijalankan. Klik Periksa lagi.';
    CheckBlocked := True;
  end;

  // Pilihan port LAN hanya ditampilkan bila ada lebih dari satu.
  AdapterBox.Items.Clear;
  AdapterIndexes.Clear;
  Lines := TStringList.Create;
  try
    Lines.Text := ReadText(ResultFile + '.adapters');
    for I := 0 to Lines.Count - 1 do begin
      Line := Lines[I];
      Sep := Pos('|', Line);
      if Sep > 0 then begin
        AdapterIndexes.Add(Copy(Line, 1, Sep - 1));
        AdapterBox.Items.Add(Copy(Line, Sep + 1, Length(Line)));
      end;
    end;
  finally
    Lines.Free;
  end;
  AdapterBox.ItemIndex := AdapterIndexes.IndexOf(ReadText(ResultFile + '.adapter'));
  AdapterLabel.Visible := AdapterIndexes.Count > 1;
  AdapterBox.Visible := AdapterIndexes.Count > 1;
end;

procedure CheckAgainClick(Sender: TObject);
begin
  RunPreflight;
end;

procedure AdapterChange(Sender: TObject);
begin
  RunPreflight;
end;

{ ---------- halaman ---------- }

procedure InitializeWizard;
var
  Role: String;
begin
  AdapterIndexes := TStringList.Create;

  RolePage := CreateInputOptionPage(wpWelcome, 'Peran komputer', 'Komputer ini akan dipakai sebagai apa?',
    'Komputer master menyimpan data dan menjalankan aplikasi (satu saja). Komputer scan membuka aplikasi dari komputer master lewat kabel LAN.',
    True, False);
  RolePage.Add('Komputer master (server, menyimpan semua data)');
  RolePage.Add('Komputer scan (titik scan, membuka aplikasi dari master)');
  Role := ParamValue('ROLE', GetPreviousData('Role', 'master'));
  if CompareText(Role, 'scan') = 0 then RolePage.SelectedValueIndex := 1 else RolePage.SelectedValueIndex := 0;

  CheckPage := CreateCustomPage(RolePage.ID, 'Pemeriksaan komputer', 'Hal yang perlu beres sebelum memasang. Tidak ada yang diubah di halaman ini.');
  CheckMemo := TNewMemo.Create(CheckPage);
  CheckMemo.Parent := CheckPage.Surface;
  CheckMemo.ReadOnly := True;
  CheckMemo.ScrollBars := ssVertical;
  CheckMemo.SetBounds(0, 0, CheckPage.SurfaceWidth, CheckPage.SurfaceHeight - ScaleY(64));
  AdapterLabel := TNewStaticText.Create(CheckPage);
  AdapterLabel.Parent := CheckPage.Surface;
  AdapterLabel.Caption := 'Port LAN untuk kabel ke switch:';
  AdapterLabel.SetBounds(0, CheckPage.SurfaceHeight - ScaleY(56), ScaleX(200), ScaleY(16));
  AdapterBox := TNewComboBox.Create(CheckPage);
  AdapterBox.Parent := CheckPage.Surface;
  AdapterBox.Style := csDropDownList;
  AdapterBox.SetBounds(0, CheckPage.SurfaceHeight - ScaleY(36), CheckPage.SurfaceWidth - ScaleX(120), ScaleY(24));
  AdapterBox.OnChange := @AdapterChange;
  CheckAgain := TNewButton.Create(CheckPage);
  CheckAgain.Parent := CheckPage.Surface;
  CheckAgain.Caption := 'Periksa lagi';
  CheckAgain.SetBounds(CheckPage.SurfaceWidth - ScaleX(110), CheckPage.SurfaceHeight - ScaleY(38), ScaleX(110), ScaleY(26));
  CheckAgain.OnClick := @CheckAgainClick;

  // Pilihan kabel ada SEBELUM halaman pemeriksaan: pemeriksaan port LAN hanya berlaku di mode kabel.
  MasterPage := CreateInputOptionPage(RolePage.ID, 'Pengaturan komputer master', 'Pilih yang dipakai di lokasi ini.', '', False, False);
  MasterPage.Add('Komputer scan tersambung lewat kabel LAN (port LAN diberi alamat tetap 192.168.77.1)');
  MasterPage.Add('Jangan tidurkan komputer ini saat dicolok listrik (disarankan)');
  MasterPage.Values[0] := ParamValue('CABLE', '1') <> '0';
  MasterPage.Values[1] := ParamValue('KEEPAWAKE', '1') <> '0';

  RestorePage := CreateInputFilePage(CheckPage.ID, 'Pulihkan data (opsional)', 'Pakai data dari backup lama?',
    'Kosongkan untuk mulai dengan data kosong. Pilih file faktur-*.sqlite (dari flashdisk atau komputer scan) untuk memulihkan.');
  RestorePage.Add('File backup:', 'Database backup (*.sqlite)|*.sqlite', '.sqlite');
  RestorePage.Values[0] := ParamValue('RESTORE', '');

  PointPage := CreateInputOptionPage(MasterPage.ID, 'Titik scan', 'Komputer scan yang mana?',
    'Tiap titik scan punya alamat kabel sendiri. Colok kabel LAN dari komputer ini ke switch sebelum Lanjut.', True, False);
  PointPage.Add('Titik scan 1 (kabel, alamat 192.168.77.2)');
  PointPage.Add('Titik scan 2 (kabel, alamat 192.168.77.3)');
  PointPage.Add('Tanpa kabel: ketik alamat komputer master sendiri');
  if ParamValue('CABLE', '1') = '0' then PointPage.SelectedValueIndex := 2
  else if ParamValue('POINT', '1') = '2' then PointPage.SelectedValueIndex := 1
  else PointPage.SelectedValueIndex := 0;

  ServerPage := CreateInputQueryPage(RestorePage.ID, 'Alamat komputer master', 'Hanya untuk pemasangan tanpa kabel',
    'Lihat INFO-PEMASANGAN.txt di komputer master.');
  ServerPage.Add('Alamat komputer master (mis. 192.168.1.10):', False);
  ServerPage.Values[0] := ParamValue('SERVER', GetPreviousData('Server', ''));

  CodePage := CreateInputQueryPage(ServerPage.ID, 'Kode pemasangan', 'Sambungkan ke komputer master',
    'Kodenya ada di ikon "Info pemasangan" di desktop komputer master (8 huruf/angka).');
  CodePage.Add('Kode pemasangan:', False);
  CodePage.Values[0] := ParamValue('CODE', '');
end;

procedure DeinitializeSetup;
begin
  if AdapterIndexes <> nil then AdapterIndexes.Free;
end;

procedure RegisterPreviousData(PreviousDataKey: Integer);
begin
  if IsMaster then SetPreviousData(PreviousDataKey, 'Role', 'master') else SetPreviousData(PreviousDataKey, 'Role', 'scan');
  if (not IsMaster) and (not UseCable) then SetPreviousData(PreviousDataKey, 'Server', ServerPage.Values[0]);
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if PageID = MasterPage.ID then Result := not IsMaster
  else if PageID = RestorePage.ID then Result := (not IsMaster) or IsUpdate
  else if PageID = PointPage.ID then Result := IsMaster
  else if PageID = ServerPage.ID then Result := IsMaster or UseCable
  else if PageID = CodePage.ID then Result := IsMaster;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = CheckPage.ID then RunPreflight;
end;

function ScanArgs(CheckOnly: Boolean): String;
begin
  Result := '-InstallDir "' + InstallDir + '" -PairingCode "' + Trim(CodePage.Values[0]) + '" -AdapterIndex ' + SelectedAdapter;
  if UseCable then Result := Result + ' -Cable -Point ' + ScanPoint
  else Result := Result + ' -Server "' + Trim(ServerPage.Values[0]) + '"';
  if CheckOnly then Result := Result + ' -CheckOnly -ResultFile "' + ExpandConstant('{tmp}\scan-check.txt') + '"';
end;

function CheckScanConnection: Boolean;
var
  Code: Integer;
  Msg: String;
begin
  ExtractScripts;
  DeleteFile(ExpandConstant('{tmp}\scan-check.txt'));
  WizardForm.NextButton.Enabled := False;
  try
    RunScript(ExpandConstant('{tmp}\setup-scan.ps1'), ScanArgs(True), Code);
  finally
    WizardForm.NextButton.Enabled := True;
  end;
  Result := Code = 0;
  if not Result then begin
    Msg := ReadText(ExpandConstant('{tmp}\scan-check.txt'));
    if Msg = '' then Msg := 'Pemeriksaan koneksi gagal dijalankan.';
    SuppressibleMsgBox(Msg, mbError, MB_OK, IDOK);
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = CheckPage.ID) and CheckBlocked then begin
    SuppressibleMsgBox('Ada pemeriksaan bertanda [X]. Bereskan dulu lalu klik Periksa lagi.', mbError, MB_OK, IDOK);
    Result := False;
  end else if (CurPageID = ServerPage.ID) and (Trim(ServerPage.Values[0]) = '') then begin
    SuppressibleMsgBox('Isi alamat komputer master.', mbError, MB_OK, IDOK);
    Result := False;
  end else if CurPageID = CodePage.ID then begin
    if Trim(CodePage.Values[0]) = '' then begin
      SuppressibleMsgBox('Isi kode pemasangan.', mbError, MB_OK, IDOK);
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
  // Mode senyap: halaman dilewati, jadi pemeriksaan & cek koneksi dijalankan di sini.
  if WizardSilent then begin
    AdapterBox.ItemIndex := -1;
    RunPreflight;
    if ParamValue('ADAPTER', '') <> '' then AdapterBox.ItemIndex := AdapterIndexes.IndexOf(ParamValue('ADAPTER', ''));
    if CheckBlocked then begin
      Result := 'Pemeriksaan komputer gagal: ' + CheckMemo.Text;
      exit;
    end;
    if (not IsMaster) and (not CheckScanConnection) then begin
      Result := 'Tidak bisa terhubung ke komputer master: ' + ReadText(ExpandConstant('{tmp}\scan-check.txt'));
      exit;
    end;
  end;
  if IsMaster and FileExists(InstallDir + '\app\artisan') then begin
    ExtractScripts;
    RunScript(ExpandConstant('{tmp}\pre-update.ps1'), '-InstallDir "' + InstallDir + '"', Code);
    if Code <> 0 then
      Result := 'Persiapan update gagal (backup sebelum-update tidak berhasil), jadi update dibatalkan dan data tidak diubah. ' +
        'Lihat ' + InstallDir + '\data\install.log';
  end;
end;

{ Baris terakhir log setup: data\ hanya bisa dibuka administrator, jadi isinya ditampilkan langsung. }
function LogTail(const Path: String): String;
var
  Lines: TArrayOfString;
  I, First: Integer;
begin
  Result := '';
  if not LoadStringsFromFile(Path, Lines) then exit;
  First := GetArrayLength(Lines) - 6;
  if First < 0 then First := 0;
  for I := First to GetArrayLength(Lines) - 1 do Result := Result + #13#10 + Lines[I];
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Code: Integer;
  Args: String;
begin
  if CurStep <> ssPostInstall then exit;
  WizardForm.StatusLabel.Caption := 'Menyiapkan aplikasi (layanan, database, jadwal, port LAN)...';
  if IsMaster then begin
    Args := '-InstallDir "' + InstallDir + '" -VcRedist "' + ExpandConstant('{tmp}\vc_redist.x64.exe') + '"';
    if UseCable then Args := Args + ' -Cable -AdapterIndex ' + SelectedAdapter;
    if MasterPage.Values[1] then Args := Args + ' -KeepAwake';
    if ParamValue('PORT', '') <> '' then Args := Args + ' -Port ' + ParamValue('PORT', '');
    if (not FileExists(InstallDir + '\data\install.json')) and (Trim(RestorePage.Values[0]) <> '') then
      Args := Args + ' -RestoreFrom "' + Trim(RestorePage.Values[0]) + '"';
    RunScript(InstallDir + '\scripts\setup-master.ps1', Args, Code);
    if Code <> 0 then
      RaiseException('Menyiapkan komputer master gagal. Kirim pesan ini ke Ashira:' + LogTail(InstallDir + '\data\install.log'));
  end else begin
    RunScript(InstallDir + '\scripts\setup-scan.ps1', ScanArgs(False), Code);
    if Code <> 0 then
      RaiseException('Menyiapkan komputer scan gagal. Kirim pesan ini ke Ashira:' + LogTail(InstallDir + '\install.log'));
  end;
  SetupOk := True;
end;
