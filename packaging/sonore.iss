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
#define AppVersion "1.6.5"
#define AppExeName "sonore.exe"
#define AppPublisher "Jekooz"
#define AppUrl "https://github.com/Jekooz/sonore"

; The staged installed layout, built by build_installer.ps1:
;
;   ..\build\packaging\stage\sonore.exe              the app
;   ..\build\packaging\stage\data\                   Flutter assets and the engine's data
;   ..\build\packaging\stage\backend\main.py         the FastAPI sidecar
;   ..\build\packaging\stage\python\python.exe       a private CPython with the sidecar's packages
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
; The installer runs elevated and creates this under Program Files, where a
; standard account has no write access, but the sidecar gets to write its own
; bytecode cache there - which is what keeps its start-up fast. Sign-in needs no
; writable folder of its own: the browser profile it uses lives per-user under
; %LOCALAPPDATA%\Sonore.
Name: "{app}\backend"; Permissions: users-modify

[InstallDelete]
; 1.6.3 and earlier shipped a helper extension the user had to load by hand.
; This build uses none, so neither the folder nor the pairing file a previous
; sign-in left in it may survive an in-place upgrade.
Type: filesandordirs; Name: "{app}\browser-extension"
; url_launcher was only there for the old "open the default browser" step.
; Inno leaves files it no longer ships in place, so name it explicitly.
Type: files; Name: "{app}\url_launcher_windows_plugin.dll"

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
    { There is no extension to load any more, which is the point of this build:
      signing in just opens a browser window. The finished page says so, so no
      one goes looking for a setup step that no longer exists. }
    WizardForm.FinishedLabel.Caption :=
      'Setup has finished installing {#AppName}.' + #13#10 + #13#10 +
      'To sign in to YouTube Music, open Sonore and choose Sign in. ' +
      'A browser window opens for your Google account and the app takes over ' +
      'on its own - there is nothing to install and no token to copy.';
  end;
end;
