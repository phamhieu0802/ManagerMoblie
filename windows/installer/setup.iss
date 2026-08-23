[Setup]
AppName=Manager MSR
AppVersion=2.1.1
AppPublisher=Manager MSR
DefaultDirName={autopf}\Manager Shop Repair
DefaultGroupName=Manager MSR
OutputDir=..\..\dist
OutputBaseFilename=Manager_MSR_Setup
Compression=lzma2
SolidCompression=yes
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\phone_repair_shop.exe
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

[Files]
Source: "..\..\build\windows\x64\runner\Release\phone_repair_shop.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\build\windows\x64\runner\Release\flutter_windows.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\build\windows\x64\runner\Release\dartjni.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\build\windows\x64\runner\Release\app_links_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\build\windows\x64\runner\Release\file_selector_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\build\windows\x64\runner\Release\flutter_secure_storage_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\build\windows\x64\runner\Release\url_launcher_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\build\windows\x64\runner\Release\data\icudtl.dat"; DestDir: "{app}\data"; Flags: ignoreversion
Source: "..\..\build\windows\x64\runner\Release\data\app.so"; DestDir: "{app}\data"; Flags: ignoreversion
Source: "..\..\build\windows\x64\runner\Release\data\flutter_assets\*"; DestDir: "{app}\data\flutter_assets"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Manager MSR"; Filename: "{app}\phone_repair_shop.exe"
Name: "{group}\Uninstall Manager MSR"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Manager MSR"; Filename: "{app}\phone_repair_shop.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Tạo shortcut trên Desktop"; GroupDescription: "Additional shortcuts:"

[Run]
Filename: "{app}\phone_repair_shop.exe"; Description: "Mở Manager MSR ngay"; Flags: nowait postinstall skipifsilent
