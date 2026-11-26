#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
for tool in ssh scp tar; do
    command -v "$tool" >/dev/null || { echo "$tool is required." >&2; exit 1; }
done

read -r -p "Server IPv4: " SERVER_IP
if [[ ! "$SERVER_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo "Enter a valid IPv4 address." >&2
    exit 1
fi
IFS=. read -r -a OCTETS <<< "$SERVER_IP"
for octet in "${OCTETS[@]}"; do
    if ((10#$octet > 255)); then
        echo "Enter a valid IPv4 address." >&2
        exit 1
    fi
done

read -r -p "SSH username: " SSH_USER
if [[ ! "$SSH_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; then
    echo "SSH username contains unsupported characters." >&2
    exit 1
fi

TARGET="$SSH_USER@$SERVER_IP"
ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/drive-tasks-mini.XXXXXX.tar.gz")"
REMOTE_ARCHIVE="drive-tasks-mini-$RANDOM-$RANDOM.tar.gz"
trap 'rm -f -- "$ARCHIVE"' EXIT

echo "[1/4] Creating Python-only Mini bundle."
tar -czf "$ARCHIVE" -C "$ROOT" VERSION requirements.txt README.md app scripts/install-mini.sh
echo "[2/4] Uploading bundle and receiver to $TARGET."
scp -o ConnectTimeout=15 "$ARCHIVE" "$TARGET:$REMOTE_ARCHIVE"
scp -o ConnectTimeout=15 "$ROOT/scripts/receive-mini.sh" "$TARGET:drive-tasks-mini-receiver.sh"
echo "[3/4] Installing or updating. Enter the sudo password if prompted."
if ssh -tt -o ConnectTimeout=15 "$TARGET" "bash \"\$HOME/drive-tasks-mini-receiver.sh\" \"\$HOME/$REMOTE_ARCHIVE\""; then
    echo "[4/4] Remote installer finished. If this version was not newer, it left the service unchanged."
    echo "Mini downloader: http://$SERVER_IP:2121"
    echo "Complete installer logs: /mnt/share/drive-tasks-mini/install-logs/ on the server."
else
    status=$?
    echo "Remote installation failed (exit $status). Review the streamed output above." >&2
    echo "Complete installer logs: /mnt/share/drive-tasks-mini/install-logs/ on the server." >&2
    exit "$status"
fi
