set VERSION=%1
set SDK_PATH=%2
set BUILD_DIRECTORY=%3

set INSTALLER_NAME="%cd%\tools\windows_installer\toit_installer.exe"

set INNO=ISCC.exe

%INNO% /Qp /dMyAppVersion=%VERSION% /dSdkPath="%SDK_PATH%" "%cd%/tools/windows_installer/installer.iss"
move %INSTALLER_NAME% %BUILD_DIRECTORY%
