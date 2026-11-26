@echo off
setlocal
pushd "%~dp0"
set "result=1"
echo [1/4] Checking required local tools...
where ssh.exe >nul 2>nul
if errorlevel 1 (
    echo OpenSSH Client is required. Install it from Windows Optional Features.
    goto :finish
)
where scp.exe >nul 2>nul
if errorlevel 1 (
    echo OpenSSH scp is required.
    goto :finish
)
where tar.exe >nul 2>nul
if errorlevel 1 (
    echo Windows tar is required.
    goto :finish
)

set /p "SERVER_IP=Server IPv4: "
echo(%SERVER_IP%| findstr /R /C:"^[0-9][0-9.]*$" >nul
if errorlevel 1 (
    echo Enter an IPv4 address using digits and dots only.
    goto :finish
)
set /p "SSH_USER=SSH username: "
echo(%SSH_USER%| findstr /R /C:"^[A-Za-z_][A-Za-z0-9_.-]*$" >nul
if errorlevel 1 (
    echo SSH username contains unsupported characters.
    goto :finish
)

set "TARGET=%SSH_USER%@%SERVER_IP%"
set "ARCHIVE=%TEMP%\drive-tasks-mini-%RANDOM%-%RANDOM%.tar.gz"
set "REMOTE_ARCHIVE=drive-tasks-mini-%RANDOM%-%RANDOM%.tar.gz"
echo [2/4] Creating Python-only Mini bundle. Local config and download data are excluded.
tar.exe -czf "%ARCHIVE%" -C "%CD%" VERSION requirements.txt README.md app scripts/install-mini.sh
if errorlevel 1 (
    echo Could not create deployment archive.
    goto :finish
)

echo [3/4] Uploading bundle and receiver to %TARGET%. Watch for the SSH password or host-key prompt.
scp.exe -o ConnectTimeout=15 "%ARCHIVE%" "%TARGET%:%REMOTE_ARCHIVE%"
if errorlevel 1 (
    echo Bundle upload failed.
    goto :finish
)
scp.exe -o ConnectTimeout=15 "scripts\receive-mini.sh" "%TARGET%:drive-tasks-mini-receiver.sh"
if errorlevel 1 (
    echo Receiver upload failed.
    goto :finish
)

echo [4/4] Installing or updating. Enter the sudo password if prompted.
ssh.exe -tt -o ConnectTimeout=15 "%TARGET%" "bash ~/drive-tasks-mini-receiver.sh ~/%REMOTE_ARCHIVE%"
if errorlevel 1 (
    echo Remote installation failed. Review the server output above.
    echo Complete installer logs are saved under /mnt/share/drive-tasks-mini/install-logs/ on the server.
    goto :finish
)

echo.
echo Mini deployment finished. If this version was not newer, the service was left unchanged.
echo Mini downloader: http://%SERVER_IP%:2121
echo Complete installer logs: /mnt/share/drive-tasks-mini/install-logs/ on the server.
set "result=0"

:finish
if defined ARCHIVE if exist "%ARCHIVE%" del /q "%ARCHIVE%"
popd
if not "%result%"=="0" pause
exit /b %result%
