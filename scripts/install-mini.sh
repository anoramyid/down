#!/usr/bin/env bash
set -Eeuo pipefail

STAGING="${1:?Usage: install-mini.sh STAGING_DIRECTORY}"
STAGING="$(cd "$STAGING" && pwd -P)"
[[ $EUID -eq 0 ]] || { echo "Run this installer with sudo." >&2; exit 1; }

DEPLOY_HOME=/root
if [[ -n "${SUDO_USER:-}" ]]; then
    DEPLOY_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [[ -n "$DEPLOY_HOME" ]] || DEPLOY_HOME=/root
fi
LOG_DIR="$DEPLOY_HOME/drive-tasks-mini-install-logs"
install -d -m 700 -o "${SUDO_USER:-root}" "$LOG_DIR"
find "$LOG_DIR" -type f -name 'install-*.log' -mtime +30 -delete
LOG_FILE="$LOG_DIR/install-$(date +%Y%m%dT%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Installer log: $LOG_FILE"

NEW_VERSION="$(tr -d '\r\n' < "$STAGING/VERSION")"
if [[ ! "$NEW_VERSION" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "VERSION must use numeric major.minor.patch format." >&2
    exit 1
fi

version_is_newer() {
    local -a newer older
    local i
    IFS=. read -r -a newer <<< "$1"
    IFS=. read -r -a older <<< "$2"
    for i in 0 1 2; do
        if ((10#${newer[$i]} > 10#${older[$i]})); then return 0; fi
        if ((10#${newer[$i]} < 10#${older[$i]})); then return 1; fi
    done
    return 1
}

BASE=/opt/drive-tasks-mini
RELEASES="$BASE/releases"
CURRENT="$BASE/current"
STATE=/var/lib/drive-tasks-mini
SERVICE=drive-tasks-mini.service
OLD_TARGET=
OLD_VERSION=0.0.0
if [[ -L "$CURRENT" ]]; then
    OLD_TARGET="$(readlink -f "$CURRENT")"
    [[ -n "$OLD_TARGET" && -f "$OLD_TARGET/VERSION" ]] || {
        echo "The existing current release link is invalid; refusing to replace it." >&2
        exit 1
    }
    OLD_VERSION="$(tr -d '\r\n' < "$OLD_TARGET/VERSION")"
    if [[ ! "$OLD_VERSION" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "The installed VERSION is invalid; refusing to replace it." >&2
        exit 1
    fi
    if ! version_is_newer "$NEW_VERSION" "$OLD_VERSION"; then
        echo "Installed Mini version $OLD_VERSION is current or newer; skipping installation."
        exit 0
    fi
elif [[ -e "$CURRENT" ]]; then
    echo "$CURRENT exists but is not a release symlink; refusing to replace it." >&2
    exit 1
fi

if [[ ! -f /etc/os-release ]] || ! grep -qiE '^(ID|ID_LIKE)=.*(debian|ubuntu)' /etc/os-release; then
    echo "Mini installation currently supports Debian/Ubuntu servers only." >&2
    exit 1
fi
command -v apt-get >/dev/null || { echo "apt-get is required." >&2; exit 1; }
command -v systemctl >/dev/null || { echo "systemd is required." >&2; exit 1; }

PYTHON_READY=1
if ! command -v python3 >/dev/null \
        || ! python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
    PYTHON_READY=0
else
    VENV_CHECK="$(mktemp -d)"
    if ! python3 -m venv "$VENV_CHECK/test" >/dev/null 2>&1; then
        PYTHON_READY=0
    fi
    rm -rf -- "$VENV_CHECK"
fi
if [[ "$PYTHON_READY" -eq 0 ]]; then
    echo "Installing Python 3 and virtual-environment support (no Docker or browser packages)."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates python3 python3-venv
fi
python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' || {
    echo "Python 3.10 or newer is required; found $(python3 --version)." >&2
    exit 1
}

SERVICE_USER=drive-tasks-mini
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --user-group --home-dir "$STATE" --no-create-home \
        --shell /usr/sbin/nologin "$SERVICE_USER"
elif ! getent group "$SERVICE_USER" >/dev/null 2>&1; then
    groupadd --system "$SERVICE_USER"
fi
install -d -o root -g root -m 755 "$BASE" "$RELEASES"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 750 \
    "$STATE" "$STATE/data" "$STATE/config"

AUTH_FILE="$STATE/config/credentials.json"
if [[ ! -f "$AUTH_FILE" ]]; then
    echo "Set the separate web-app login (not the SSH login)."
    read -r -p "Application username: " APP_USER </dev/tty
    if [[ ! "$APP_USER" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
        echo "Application username may contain letters, numbers, dot, underscore and hyphen." >&2
        exit 1
    fi
    while true; do
        read -r -s -p "Application password (6-128 characters): " APP_PASS </dev/tty
        echo
        if (( ${#APP_PASS} < 6 || ${#APP_PASS} > 128 )); then
            echo "Application password must be 6-128 characters."
            continue
        fi
        read -r -s -p "Confirm application password: " APP_PASS_CONFIRM </dev/tty
        echo
        if [[ "$APP_PASS" != "$APP_PASS_CONFIRM" ]]; then
            echo "Passwords do not match."
            continue
        fi
        break
    done
    APP_USER="$APP_USER" APP_PASS="$APP_PASS" AUTH_FILE="$AUTH_FILE" python3 - <<'PY'
import json
import os

path = os.environ["AUTH_FILE"]
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as output:
    json.dump(
        {"APP_USER": os.environ["APP_USER"], "APP_PASS": os.environ["APP_PASS"]},
        output,
    )
    output.write("\n")
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY
    chown "$SERVICE_USER:$SERVICE_USER" "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
else
    AUTH_FILE="$AUTH_FILE" python3 - <<'PY'
import json
import os

with open(os.environ["AUTH_FILE"], encoding="utf-8") as source:
    credentials = json.load(source)
if (not isinstance(credentials, dict)
        or not isinstance(credentials.get("APP_USER"), str)
        or not isinstance(credentials.get("APP_PASS"), str)):
    raise SystemExit("Stored credentials file is invalid.")
PY
    chown "$SERVICE_USER:$SERVICE_USER" "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
fi

RELEASE_DIR="$(mktemp -d "$RELEASES/${NEW_VERSION}.XXXXXX")"
cp -a "$STAGING/." "$RELEASE_DIR/"
python3 -m venv "$RELEASE_DIR/.venv"
"$RELEASE_DIR/.venv/bin/python" -m pip install --upgrade pip
"$RELEASE_DIR/.venv/bin/python" -m pip install -r "$RELEASE_DIR/requirements.txt"
chown -R "$SERVICE_USER:$SERVICE_USER" "$RELEASE_DIR"

cat > /etc/drive-tasks-mini.env <<EOF
ROOT=$STATE/data
CONFIG_DIR=$STATE/config
BROWSER_DOWNLOAD_DIR=$STATE/data/browser
AUTH_FILE=$AUTH_FILE
ENABLE_BROWSER=0
PORT=2121
MAX_PARALLEL=2
DOWNLOAD_LIMIT_MIB=5
LOG_LEVEL=INFO
PYTHONUNBUFFERED=1
PYTHONDONTWRITEBYTECODE=1
EOF
chmod 600 /etc/drive-tasks-mini.env

cat > "/etc/systemd/system/$SERVICE" <<'UNIT'
[Unit]
Description=Drive Tasks Mini Python downloader
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=drive-tasks-mini
Group=drive-tasks-mini
WorkingDirectory=/opt/drive-tasks-mini/current
EnvironmentFile=/etc/drive-tasks-mini.env
ExecStart=/opt/drive-tasks-mini/current/.venv/bin/python /opt/drive-tasks-mini/current/app/app.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/drive-tasks-mini

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "$SERVICE"
ln -s "$RELEASE_DIR" "$BASE/current.next"
mv -Tf "$BASE/current.next" "$CURRENT"

healthy() {
    python3 - <<'PY'
import urllib.error
import urllib.request

try:
    urllib.request.urlopen("http://127.0.0.1:2121/api/settings", timeout=1)
except urllib.error.HTTPError as error:
    raise SystemExit(0 if error.code == 401 else 1)
except Exception:
    raise SystemExit(1)
PY
}

if systemctl restart "$SERVICE"; then
    for _ in {1..20}; do
        if systemctl is-active --quiet "$SERVICE" && healthy; then
            echo "Drive Tasks Mini $NEW_VERSION is healthy at http://<server-ip>:2121"
            break
        fi
        sleep 1
    done
    if systemctl is-active --quiet "$SERVICE" && healthy; then
        if [[ -n "$OLD_TARGET" ]]; then
            while IFS= read -r -d '' candidate; do
                [[ "$candidate" == "$OLD_TARGET" ]] && continue
                if [[ -f "$candidate/VERSION" ]]; then
                    rm -rf -- "$candidate"
                fi
            done < <(find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -mtime +30 -print0)
        fi
        exit 0
    fi
fi

echo "Service health check failed; rolling back the application release." >&2
systemctl --no-pager --full status "$SERVICE" || true
journalctl -u "$SERVICE" --no-pager -n 40 || true
if [[ -n "$OLD_TARGET" ]]; then
    ln -s "$OLD_TARGET" "$BASE/current.rollback"
    mv -Tf "$BASE/current.rollback" "$CURRENT"
    systemctl restart "$SERVICE" || true
    echo "Restored version $OLD_VERSION; data and configuration were not changed." >&2
else
    systemctl stop "$SERVICE" || true
    rm -f "$CURRENT"
    echo "First install failed; no application release is active." >&2
fi
exit 1
