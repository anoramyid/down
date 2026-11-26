#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

for command_name in ssh scp tar; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$command_name" >&2
        exit 1
    fi
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
if [[ ! "$SSH_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,63}$ ]]; then
    echo "SSH username contains unsupported characters." >&2
    exit 1
fi

TARGET="${SSH_USER}@${SERVER_IP}"
ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/drive-tasks.XXXXXX")"
trap 'rm -f -- "$ARCHIVE"' EXIT

echo "Creating deployment bundle (local .env, config and data are excluded)..."
tar -czf "$ARCHIVE" -C "$PROJECT_DIR" -- \
    Dockerfile docker-compose.yml README.md .dockerignore .env.example \
    app scripts/install-server.sh

echo "Copying files to ${TARGET}. OpenSSH will prompt for the SSH password if needed."
scp "$ARCHIVE" "${TARGET}:drive-tasks-deploy.tar.gz"

echo "Installing or updating Drive Tasks on the remote Linux server..."
ssh -tt "$TARGET" \
    'install_dir="$HOME/drive-tasks"; mkdir -p "$install_dir" && tar -xzf "$HOME/drive-tasks-deploy.tar.gz" -C "$install_dir" && rm -f "$HOME/drive-tasks-deploy.tar.gz" && cd "$install_dir" && bash scripts/install-server.sh'

printf '\nDeployment complete.\nDownloader: http://%s:9191\nChromium:   https://%s:3001\n' "$SERVER_IP" "$SERVER_IP"
