#!/usr/bin/env bash
set -Eeuo pipefail

ARCHIVE="${1:?Usage: receive-mini.sh ARCHIVE}"
[[ -f "$ARCHIVE" ]] || { echo "Deployment archive not found: $ARCHIVE" >&2; exit 1; }
STAGING="$(mktemp -d "$HOME/drive-tasks-mini-stage.XXXXXX")"
cleanup() {
    rm -rf -- "$STAGING"
    rm -f -- "$ARCHIVE"
    rm -f -- "$HOME/drive-tasks-mini-receiver.sh"
}
trap cleanup EXIT

tar -xzf "$ARCHIVE" -C "$STAGING"
[[ -f "$STAGING/scripts/install-mini.sh" ]] || {
    echo "The deployment archive does not contain the Mini installer." >&2
    exit 1
}
if [[ $EUID -eq 0 ]]; then
    bash "$STAGING/scripts/install-mini.sh" "$STAGING"
else
    sudo bash "$STAGING/scripts/install-mini.sh" "$STAGING"
fi
