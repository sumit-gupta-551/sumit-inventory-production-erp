; -----------------------------------------------------------------------------
; SSSJ ERP — Inno Setup script
; Build the Flutter Windows release first:
;     flutter build windows --release
; Then open this file in Inno Setup Compiler and click "Build > Compile".
; The installer will be produced at: D:\SSSJ_ERP_Build\SSSJ_ERP_Setup.exe
; -----------------------------------------------------------------------------

#define MyAppName        "SSSJ ERP"
#define MyAppVersion     "1.0.0"
#define MyAppPublisher   "SSSJ"
#define MyAppExeName     "erp_inventory.exe"
#define MyBuildDir       "build\windows\x64\runner\Release"

[Setup]
AppId={{8B7E4E0D-1A2C-4F4F-9C2A-7B5E1F2D9A11}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=D:\SSSJ_ERP_Build
OutputBaseFilename=SSSJ_ERP_Setup
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64
ArchitecturesAllowed=x64
PrivilegesRequired=lowest
WizardStyle=modern
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; \
    GroupDescription: "Additional icons:"; Flags: checkedonce

[Files]
; Bundle the entire Flutter release output (exe, DLLs, data folder, plugins).
Source: "{#MyBuildDir}\*"; DestDir: "{app}"; \
    Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{commondesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; \
    Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; \
    Description: "Launch {#MyAppName}"; \
    Flags: nowait postinstall skipifsilent
