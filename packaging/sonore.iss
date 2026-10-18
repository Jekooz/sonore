; Sonore - single-file Windows installer.
;
; Compile it through packaging\build_installer.ps1, which builds the app, the
; private CPython runtime and the stage this script packages, and which also
; checks that AppVersion below still matches ytm_app\pubspec.yaml.
;
; Every Source path is relative to this script's own folder (Inno Setup's
; SourcePath), so nothing has to be passed on the command line and no path
; quoting can go wrong.

#define AppName "Sonore"
#define AppVersion "1.0.0"
#define AppExeName "sonore.exe"
#define AppPublisher "Jekooz"
#define AppUrl "https://github.com/Jekooz/sonore"

; The staged installed layout, built by build_installer.ps1:
;
;   ..\build\packaging\stage\sonore.exe              the app
;   ..\build\packaging\stage\data\                   Flutter assets and the engine's data
;   ..\build\packaging\stage\backend\main.py         the FastAPI sidecar
;   ..\build\packaging\stage\python\python.exe       a private CPython with the sidecar's packages
;   ..\build\packaging\stage\browser-extension\      the sign-in helper
;   ..\build\packaging\stage\yt-dlp.exe              the tool the sidecar shells out to
;   ..\build\packaging\stage\vc_redist.x64.exe       Microsoft's VC++ runtime, installed only if missing
#define StageDir "..\build\packaging\stage"

[Setup]
; A stable Id: upgrades and the Add or remove programs entry stay one product.
AppId={{8F2B7C41-5A9E-4E3D-9C61-2B7E4F0A6D13}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename={#AppName}-Setup-{#AppVersion}
SetupIconFile=..\ytm_app\windows\runner\resources\app_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; The app is 64-bit only, and x64compatible accepts both x64 and Arm64 Windows.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
; The default install is for every account on the machine, which needs the one
; UAC prompt. /CURRENTUSER on the command line installs for one account instead,
; which is also how this is tested without an interactive prompt.
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=commandline

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Everything the app needs at run time, flat in one folder. That flat shape is
; what the app's resolver looks for: the sidecar in backend\, the interpreter in
; python\ and the tools beside the executable.
Source: "{#StageDir}\*"; DestDir: "{app}"; Excludes: "vc_redist.x64.exe"; Flags: ignoreversion recursesubdirs createallsubdirs
; Extracted to a temporary folder only, and only when the machine lacks the
; runtime, because Microsoft's own installer owns the actual deployment.
Source: "{#StageDir}\vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall; Check: NeedsVcRedist

[Dirs]
; Sign-in writes a short-lived pairing token into the extension folder, and an
; extension page can only read a file from inside its own folder - so this folder
; has to be writable by the account that runs the app, while the installer itself
; runs elevated and creates it under Program Files, where a standard account has
; no write access. The sidecar also gets to write its bytecode cache, which keeps
; its start-up fast.
Name: "{app}\browser-extension"; Permissions: users-modify
Name: "{app}\backend"; Permissions: users-modify

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
; Microsoft's runtime installs silently and only once: the redistributable skips
; itself when a newer one is already present. A reboot request (3010) is not a
; failure, so its exit code is deliberately not treated as one.
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Installing the Microsoft Visual C++ runtime..."; Flags: waituntilterminated; Check: NeedsVcRedist
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Written while the app runs, so the uninstaller has no record of them.
Type: files; Name: "{app}\browser-extension\sidecar.json"
Type: files; Name: "{app}\browser-extension\sidecar.json.tmp"
Type: filesandordirs; Name: "{app}\backend\__pycache__"
Type: filesandordirs; Name: "{app}\backend\services\__pycache__"

[Code]
function NeedsVcRedist(): Boolean;
var
  Installed: Cardinal;
begin
  { The redistributable records itself here. A machine that already has it is
    left completely alone: no download, no installer run. }
  if RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Installed', Installed) then
    Result := Installed <> 1
  else
    Result := True;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpFinished then
  begin
    { Sign-in depends on the bundled extension, so its folder is named on the
      page the user actually reads. }
    WizardForm.FinishedLabel.Caption :=
      'Setup has finished installing {#AppName}.' + #13#10 + #13#10 +
      'To sign in to YouTube Music, load the helper extension that shipped with the app: ' +
      'open your browser''s extension page (chrome://extensions in Chrome, Edge or Brave), ' +
      'turn on Developer mode, choose "Load unpacked" and select' + #13#10 +
      ExpandConstant('{app}\browser-extension');
  end;
end;
