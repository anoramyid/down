#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

umask 077
LOG_DIR="$HOME/drive-tasks-install-logs"
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
find "$LOG_DIR" -maxdepth 1 -type f -name 'install-*.log' -mtime +30 -delete
LOG_FILE="$LOG_DIR/install-$(date -u +%Y%m%dT%H%M%SZ).log"
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'status=$?; if ((status != 0)); then printf "\nInstaller failed (exit %s); recent output follows (full log: %s)\n" "$status" "$LOG_FILE"; tail -n 60 "$LOG_FILE"; fi' EXIT

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "This installer supports Linux servers only." >&2
    exit 1
fi
if [[ ! -f /etc/os-release ]]; then
    echo "Cannot identify this Linux distribution." >&2
    exit 1
fi

SUDO=()
if ((EUID != 0)); then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "Install as root or provide a user with sudo access." >&2
        exit 1
    fi
    echo "Checking sudo access; enter the server sudo password if prompted."
    sudo -v
    SUDO=(sudo)
fi

install_curl() {
    if command -v curl >/dev/null 2>&1; then
        return
    fi
    if command -v apt-get >/dev/null 2>&1; then
        "${SUDO[@]}" apt-get update
        "${SUDO[@]}" apt-get install -y ca-certificates curl
    elif command -v dnf >/dev/null 2>&1; then
        "${SUDO[@]}" dnf install -y ca-certificates curl
    elif command -v yum >/dev/null 2>&1; then
        "${SUDO[@]}" yum install -y ca-certificates curl
    else
        echo "Install curl and rerun this script." >&2
        exit 1
    fi
}

if ! command -v docker >/dev/null 2>&1; then
    install_curl
    echo "Installing Docker Engine and Compose using Docker's official installation script..."
    curl -fsSL https://get.docker.com | "${SUDO[@]}" sh
fi

if ! docker compose version >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        "${SUDO[@]}" apt-get update
        "${SUDO[@]}" apt-get install -y docker-compose-plugin
    elif command -v dnf >/dev/null 2>&1; then
        "${SUDO[@]}" dnf install -y docker-compose-plugin
    elif command -v yum >/dev/null 2>&1; then
        "${SUDO[@]}" yum install -y docker-compose-plugin
    else
        echo "Docker Compose plugin is missing; install it and rerun this script." >&2
        exit 1
    fi
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose is still unavailable after installation." >&2
    exit 1
fi

if ! docker info >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
    if systemctl cat docker.service >/dev/null 2>&1; then
        "${SUDO[@]}" systemctl enable --now docker
    fi
fi

if [[ ! -f .env ]]; then
    echo "Set the separate web-app login (not the SSH login)."
    read -r -p "Application username: " APP_USER </dev/tty
    if [[ ! "$APP_USER" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
        echo "Use 1-64 letters, numbers, dots, underscores or hyphens for the application username." >&2
        exit 1
    fi
    read -r -s -p "Application password (6-128 characters; no single quote or backslash): " APP_PASS </dev/tty
    echo
    if ((${#APP_PASS} < 6 || ${#APP_PASS} > 128)); then
        echo "Application password must be 6-128 characters long." >&2
        exit 1
    fi
    case "$APP_PASS" in
        *"'"*|*\\*)
        echo "Application password cannot contain a single quote or backslash." >&2
        exit 1
        ;;
    esac
    read -r -s -p "Confirm application password: " APP_PASS_CONFIRM </dev/tty
    echo
    if [[ "$APP_PASS" != "$APP_PASS_CONFIRM" ]]; then
        echo "Passwords do not match." >&2
        exit 1
    fi

    umask 077
    printf "DATA_DIR=./data\nBIND_IP=0.0.0.0\nAPP_USER='%s'\nAPP_PASS='%s'\nLOG_LEVEL=INFO\nDOWNLOAD_LIMIT_MIB=5\n" \
        "$APP_USER" "$APP_PASS" > .env
    chmod 600 .env
elif ! grep -Eq '^APP_USER=.+$' .env || ! grep -Eq '^APP_PASS=.+$' .env; then
    echo "Existing .env must contain non-empty APP_USER and APP_PASS values; it was not overwritten." >&2
    exit 1
fi

if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
else
    DOCKER=("${SUDO[@]}" docker)
fi

echo "Validating Compose configuration..."
"${DOCKER[@]}" compose config --quiet
echo "Building and starting Drive Tasks and Chromium..."
"${DOCKER[@]}" compose up -d --build
"${DOCKER[@]}" compose ps
