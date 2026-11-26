@echo off
setlocal
pushd "%~dp0"
set "result=1"
echo [1/5] Checking required local tools...
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
set "ARCHIVE=%TEMP%\drive-tasks-%RANDOM%-%RANDOM%.tar.gz"
echo [2/5] Creating deployment bundle. Local .env, config and data are excluded.
tar.exe -czf "%ARCHIVE%" -C "%CD%" Dockerfile docker-compose.yml README.md .dockerignore .env.example requirements.txt app scripts/install-server.sh
if errorlevel 1 (
    echo Could not create deployment archive.
    goto :finish
)

echo [3/5] Uploading files to %TARGET%. Watch for the SSH password or host-key prompt.
scp.exe -o ConnectTimeout=15 "%ARCHIVE%" "%TARGET%:drive-tasks-deploy.tar.gz"
if errorlevel 1 (
    echo File transfer failed.
    goto :finish
)

echo [4/5] Extracting source on the server. SSH may ask for the password again.
ssh.exe -o ConnectTimeout=15 "%TARGET%" "mkdir -p ~/drive-tasks && tar -xzf ~/drive-tasks-deploy.tar.gz -C ~/drive-tasks && rm -f ~/drive-tasks-deploy.tar.gz"
if errorlevel 1 (
    echo Could not extract deployment archive on the server.
    goto :finish
)

echo [5/5] Building and starting on the server.
echo Docker build output will appear below; this can take several minutes on first install.
echo Enter sudo or application credentials only when their prompts appear.
ssh.exe -tt -o ConnectTimeout=15 "%TARGET%" "cd ~/drive-tasks && bash scripts/install-server.sh"
if errorlevel 1 (
    echo Remote installation failed. Review the server output above.
    echo Installer logs are saved under ~/drive-tasks-install-logs/ on the server.
    goto :finish
)

echo.
echo Deployment complete.
echo Downloader: http://%SERVER_IP%:9191
echo Chromium:   https://%SERVER_IP%:3001
set "result=0"

:finish
if defined ARCHIVE if exist "%ARCHIVE%" del /q "%ARCHIVE%"
popd
if not "%result%"=="0" pause
exit /b %result%
