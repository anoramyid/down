@echo off
setlocal
set "BASE_URL=http://10.10.100.109:3000"
set "REPO_URL=%BASE_URL%/anton/down.git"

git credential-manager --version >nul 2>nul
if errorlevel 1 (
    echo Git Credential Manager is required. Install Git for Windows and configure its credential helper.
    pause
    exit /b 1
)

echo The Git server uses HTTP. Continue only on a trusted LAN; tokens are not encrypted in transit.
start "" "%BASE_URL%/user/login"
echo Sign in and complete OTP in the browser, then return here.
pause
start "" "%BASE_URL%/user/settings/applications"
echo Create a repository-scoped access token with the minimum read/write permissions.
echo After creating the token, return here and press a key to authenticate Git.
pause

git ls-remote "%REPO_URL%"
if errorlevel 1 (
    echo Git authentication failed. In the Credential Manager prompt, use your Git username and access token.
    pause
    exit /b 1
)

echo Git authentication succeeded. The credential helper should now remember the token.
pause
exit /b 0
