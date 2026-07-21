; ============================================================================
; Slate - per-user installer (Telegram/Discord style: no admin, %LocalAppData%).
; Built by tools/build_installer.ps1, which assembles the release bundle first.
; NOT code-signed (no cert yet) - SmartScreen still warns strangers; fine for
; hand-installed wave-0 testers with the "More info -> Run anyway" instruction.
; Kept ASCII-only on purpose to avoid ANSI/UTF-8 decode surprises.
; ============================================================================

#ifndef MyAppVersion
  #define MyAppVersion "1.1.3"
#endif
#define MyAppName "Slate"
#define MyAppPublisher "Kael"
#define MyAppExeName "slate.exe"

; Self-locating: SourcePath is this .iss's folder (with trailing backslash).
#define StagingDir SourcePath + "..\build\windows\x64\runner\Release"
#define IconFile   SourcePath + "..\icon.ico"
#define OutDir     SourcePath + "..\Releases"

[Setup]
; Fixed AppId forever: the next Slate_Setup upgrades in place, never duplicates.
AppId={{1F4B13C7-CE80-4304-92EA-F243B6060C06}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppCopyright=Copyright (C) 2026 Kael
VersionInfoCompany=Kael
VersionInfoProductName=Slate
VersionInfoVersion={#MyAppVersion}
; Per-user install, no UAC / admin (matches asInvoker + PerMonitorV2 manifest).
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Kael\Slate
DefaultGroupName=Slate
DisableProgramGroupPage=yes
UninstallDisplayName=Slate
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile={#IconFile}
OutputDir={#OutDir}
OutputBaseFilename=Slate_Setup_v{#MyAppVersion}
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; We terminate Slate ourselves (window-close only hides to tray); don't let
; Inno's own WM_CLOSE dance run - it would just hide the app, not free the files.
CloseApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
; Checked by default (user decision): a visible desktop icon reminds a new
; tester the app exists. They can uncheck.
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#StagingDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
; All runtime DLLs at the bundle root: flutter_windows, every *_plugin.dll,
; slate_core.dll, AND the app-local VC++ runtime (msvcp140 / vcruntime140 /
; vcruntime140_1) that build_installer.ps1 stages here - a clean tester machine
; may lack them, and without them slate.exe won't start.
Source: "{#StagingDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StagingDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Slate"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall Slate"; Filename: "{uninstallexe}"
Name: "{userdesktop}\Slate"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,Slate}"; Flags: nowait postinstall skipifsilent

[Code]
procedure KillRunningSlate;
var
  ResultCode: Integer;
begin
  // Catches the main process and the child --pill window (same exe name).
  Exec(ExpandConstant('{cmd}'), '/C taskkill /IM slate.exe /F', '',
       SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

// Free the files before overwriting on install/upgrade.
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  KillRunningSlate;
  Result := '';
end;

// Before uninstall removes files: stop the app, then clear the autostart value
// the app wrote (else a dangling HKCU\Run entry points at a deleted exe).
// User data (slate_data, outside {app}) is intentionally left untouched.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    KillRunningSlate;
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'Slate');
  end;
end;
