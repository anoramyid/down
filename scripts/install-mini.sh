#!/usr/bin/env bash
set -Eeuo pipefail

STAGING="${1:?Usage: install-mini.sh STAGING_DIRECTORY}"
STAGING="$(cd "$STAGING" && pwd -P)"
[[ $EUID -eq 0 ]] || { echo "Run this installer with sudo." >&2; exit 1; }

SHARE_ROOT=/mnt/share
BASE="$SHARE_ROOT/drive-tasks-mini"
RELEASES="$BASE/releases"
CURRENT_RELEASE="$BASE/current-release"
STATE="$BASE/state"
LEGACY_BASE=/opt/drive-tasks-mini
LEGACY_STATE=/var/lib/drive-tasks-mini
SERVICE=drive-tasks-mini.service
SERVICE_FILE="/etc/systemd/system/$SERVICE"
ENV_FILE=/etc/drive-tasks-mini.env
mkdir -p "$SHARE_ROOT"
install -d -m 755 "$BASE"

LOG_DIR="$BASE/install-logs"
install -d -m 700 -o "${SUDO_USER:-root}" "$LOG_DIR"
find "$LOG_DIR" -type f -name 'install-*.log' -mtime +30 -delete
LOG_FILE="$LOG_DIR/install-$(date +%Y%m%dT%H%M%S)-$$.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Installer log: $LOG_FILE"
echo "Starting Drive Tasks Mini installer."

BACKUP_DIR=
CONFIG_STAGE=
cleanup_backup() {
    [[ -z "$BACKUP_DIR" ]] || rm -rf -- "$BACKUP_DIR"
    [[ -z "$CONFIG_STAGE" ]] || rm -rf -- "$CONFIG_STAGE"
}
finish_install() {
    local status=$?
    cleanup_backup
    if [[ $status -eq 0 ]]; then
        echo "[SUCCESS] Installer finished. Full log: $LOG_FILE"
    else
        echo "[FAIL] Installer exited with code $status. Full log: $LOG_FILE" >&2
    fi
    exit "$status"
}
trap finish_install EXIT

echo "[1/8] Checking release version."
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

run_with_progress() {
    local label="$1"
    local process_id
    local elapsed=0
    local status
    shift
    echo "[RUN] $label"
    "$@" &
    process_id=$!
    while kill -0 "$process_id" 2>/dev/null; do
        sleep 1
        if kill -0 "$process_id" 2>/dev/null; then
            elapsed=$((elapsed + 1))
            if ((elapsed % 5 == 0)); then
                echo "[RUNNING] $label is still running (${elapsed}s elapsed)."
            fi
        fi
    done
    if wait "$process_id"; then
        echo "[OK] $label"
    else
        status=$?
        echo "[FAIL] $label (exit $status)." >&2
        return "$status"
    fi
}

OLD_TARGET=
OLD_VERSION=0.0.0
LEGACY_TARGET=
LEGACY_MIGRATION=0
if [[ -f "$CURRENT_RELEASE" && ! -L "$CURRENT_RELEASE" ]]; then
    OLD_TARGET="$(tr -d '\r\n' < "$CURRENT_RELEASE")"
    OLD_TARGET="$(readlink -f "$OLD_TARGET")"
    RELEASES_REAL="$(readlink -f "$RELEASES")"
    case "$OLD_TARGET" in
        "$RELEASES_REAL"/*) ;;
        *)
            echo "The current release marker is invalid; refusing to replace it." >&2
            exit 1
            ;;
    esac
    [[ -f "$OLD_TARGET/VERSION" ]] || {
        echo "The current release is missing VERSION; refusing to replace it." >&2
        exit 1
    }
    OLD_VERSION="$(tr -d '\r\n' < "$OLD_TARGET/VERSION")"
    if [[ ! "$OLD_VERSION" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "The installed VERSION is invalid; refusing to replace it." >&2
        exit 1
    fi
    echo "Bundle version: $NEW_VERSION; installed version: $OLD_VERSION."
    if ! version_is_newer "$NEW_VERSION" "$OLD_VERSION"; then
        echo "Installed Mini version $OLD_VERSION is current or newer; skipping installation."
        exit 0
    fi
elif [[ -e "$CURRENT_RELEASE" || -L "$CURRENT_RELEASE" ]]; then
    echo "$CURRENT_RELEASE exists but is not a valid release marker; refusing to replace it." >&2
    exit 1
elif [[ -L "$LEGACY_BASE/current" ]]; then
    LEGACY_TARGET="$(readlink -f "$LEGACY_BASE/current")"
    [[ -n "$LEGACY_TARGET" && -f "$LEGACY_TARGET/VERSION" ]] || {
        echo "The previous Lite release link is invalid; refusing to migrate it." >&2
        exit 1
    }
    OLD_VERSION="$(tr -d '\r\n' < "$LEGACY_TARGET/VERSION")"
    if [[ ! "$OLD_VERSION" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "The previous Lite VERSION is invalid; refusing to migrate it." >&2
        exit 1
    fi
    echo "Bundle version: $NEW_VERSION; previous Lite version: $OLD_VERSION."
    if version_is_newer "$OLD_VERSION" "$NEW_VERSION"; then
        echo "The previous Lite version $OLD_VERSION is newer; update the local VERSION before migrating." >&2
        exit 1
    fi
    LEGACY_MIGRATION=1
elif [[ -e "$LEGACY_BASE/current" ]]; then
    echo "$LEGACY_BASE/current exists but is not a release symlink; refusing to migrate it." >&2
    exit 1
else
    echo "Bundle version: $NEW_VERSION; no existing Lite release found."
fi

echo "[2/8] Checking Debian/Ubuntu and Python requirements."
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
    run_with_progress "Update package lists" apt-get update
    run_with_progress "Install Python and virtual-environment support" \
        apt-get install -y ca-certificates python3 python3-venv
fi
python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' || {
    echo "Python 3.10 or newer is required; found $(python3 --version)." >&2
    exit 1
}
echo "Using $(python3 --version)."

echo "[3/8] Preparing /mnt/share and migrating existing data if present."
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

EXEC_CHECK="$BASE/.exec-check-$$"
if ! printf '#!/bin/sh\nexit 0\n' > "$EXEC_CHECK" \
        || ! chmod 700 "$EXEC_CHECK" || ! "$EXEC_CHECK"; then
    rm -f -- "$EXEC_CHECK"
    echo "/mnt/share must allow executable files for the Lite service." >&2
    exit 1
fi
rm -f -- "$EXEC_CHECK"

if [[ -d "$LEGACY_STATE" && ! -f "$CURRENT_RELEASE" ]]; then
    echo "Copying existing Lite configuration and downloads to $STATE (old data is kept)."
    cp -a -n "$LEGACY_STATE/." "$STATE/"
    chown -R "$SERVICE_USER:$SERVICE_USER" "$STATE/config"
fi
chown "$SERVICE_USER:$SERVICE_USER" "$STATE" "$STATE/data" "$STATE/config"
chmod 750 "$STATE" "$STATE/data" "$STATE/config"
if ! runuser -u "$SERVICE_USER" -- test -w "$STATE/data" \
        || ! runuser -u "$SERVICE_USER" -- test -w "$STATE/config"; then
    echo "$STATE must be writable by the drive-tasks-mini service user." >&2
    echo "Check /mnt/share mount ownership and permissions." >&2
    exit 1
fi

AUTH_FILE="$STATE/config/credentials.json"
echo "[4/8] Checking application credentials."
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
echo "[5/8] Creating virtualenv and installing Python dependencies in $RELEASE_DIR."
run_with_progress "Create the Python virtualenv" \
    python3 -m venv --copies "$RELEASE_DIR/.venv"
run_with_progress "Upgrade pip" \
    "$RELEASE_DIR/.venv/bin/python" -m pip install --progress-bar on --upgrade pip
run_with_progress "Install application dependencies" \
    "$RELEASE_DIR/.venv/bin/python" -m pip install --progress-bar on \
    -r "$RELEASE_DIR/requirements.txt"
chown -R "$SERVICE_USER:$SERVICE_USER" "$RELEASE_DIR"

echo "[6/8] Writing systemd service configuration."
BACKUP_DIR="$(mktemp -d)"
for existing in "$SERVICE_FILE" "$ENV_FILE" "$CURRENT_RELEASE"; do
    if [[ -f "$existing" ]]; then
        cp -a "$existing" "$BACKUP_DIR/"
    fi
done

rollback_install() {
    systemctl stop "$SERVICE" || true
    if [[ -f "$BACKUP_DIR/$SERVICE" ]]; then
        cp -a "$BACKUP_DIR/$SERVICE" "$SERVICE_FILE"
    else
        rm -f "$SERVICE_FILE"
    fi
    if [[ -f "$BACKUP_DIR/drive-tasks-mini.env" ]]; then
        cp -a "$BACKUP_DIR/drive-tasks-mini.env" "$ENV_FILE"
    else
        rm -f "$ENV_FILE"
    fi
    if [[ -f "$BACKUP_DIR/current-release" ]]; then
        cp -a "$BACKUP_DIR/current-release" "$CURRENT_RELEASE"
    else
        rm -f "$CURRENT_RELEASE"
    fi
    systemctl daemon-reload || true
    if [[ -f "$BACKUP_DIR/$SERVICE" ]]; then
        systemctl restart "$SERVICE" || true
    else
        systemctl disable "$SERVICE" || true
    fi
}

CONFIG_STAGE="$(mktemp -d /etc/drive-tasks-mini-update.XXXXXX)"
cat > "$CONFIG_STAGE/drive-tasks-mini.env" <<EOF
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
chmod 600 "$CONFIG_STAGE/drive-tasks-mini.env"

cat > "$CONFIG_STAGE/$SERVICE" <<UNIT
[Unit]
Description=Drive Tasks Mini Python downloader
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=drive-tasks-mini
Group=drive-tasks-mini
WorkingDirectory=$RELEASE_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$RELEASE_DIR/.venv/bin/python $RELEASE_DIR/app/app.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$STATE

[Install]
WantedBy=multi-user.target
UNIT
chmod 644 "$CONFIG_STAGE/$SERVICE"
if ! mv -f "$CONFIG_STAGE/drive-tasks-mini.env" "$ENV_FILE"; then
    echo "Could not install the systemd environment file; restoring previous configuration." >&2
    rollback_install
    exit 1
fi
if ! mv -f "$CONFIG_STAGE/$SERVICE" "$SERVICE_FILE"; then
    echo "Could not install the systemd unit; restoring previous configuration." >&2
    rollback_install
    exit 1
fi
rm -rf -- "$CONFIG_STAGE"
CONFIG_STAGE=

if ! systemctl daemon-reload || ! systemctl enable "$SERVICE"; then
    echo "Could not load or enable the systemd service; restoring previous configuration." >&2
    rollback_install
    exit 1
fi

echo "[7/8] Starting service and checking health on TCP 2121."
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
    for attempt in {1..20}; do
        if systemctl is-active --quiet "$SERVICE" && healthy; then
            echo "Drive Tasks Mini $NEW_VERSION is healthy at http://<server-ip>:2121"
            break
        fi
        if ((attempt % 5 == 0)); then
            echo "[RUNNING] Waiting for the service health check (${attempt}/20 seconds)."
        fi
        sleep 1
    done
    if systemctl is-active --quiet "$SERVICE" && healthy; then
        CURRENT_STAGE="$BASE/.current-release-$$"
        if ! printf '%s\n' "$RELEASE_DIR" > "$CURRENT_STAGE" \
                || ! mv -f "$CURRENT_STAGE" "$CURRENT_RELEASE" \
                || ! chmod 644 "$CURRENT_RELEASE"; then
            rm -f -- "$CURRENT_STAGE"
            echo "Could not save the active release marker; rolling back." >&2
            rollback_install
            exit 1
        fi
        if [[ -n "$OLD_TARGET" ]]; then
            while IFS= read -r -d '' candidate; do
                [[ "$candidate" == "$OLD_TARGET" ]] && continue
                if [[ -f "$candidate/VERSION" ]]; then
                    rm -rf -- "$candidate"
                fi
            done < <(find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -mtime +30 -print0)
        fi
        echo "[8/8] Installation completed at $BASE."
        exit 0
    fi
fi

echo "Service health check failed; rolling back the application release." >&2
systemctl --no-pager --full status "$SERVICE" || true
journalctl -u "$SERVICE" --no-pager -n 40 || true
if [[ -n "$OLD_TARGET" || "$LEGACY_MIGRATION" -eq 1 ]]; then
    rollback_install
    echo "Restored version $OLD_VERSION; the original data and configuration were preserved." >&2
else
    rollback_install
    echo "First install failed; no application release is active." >&2
fi
exit 1
