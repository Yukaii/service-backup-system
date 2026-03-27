#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

export HOME="$workdir/home"
export BACKUP_BASE_DIR="$workdir/backups"
export LOG_FILE="$HOME/logs/test.log"
mkdir -p "$BACKUP_BASE_DIR" "$HOME/logs"
mkdir -p "$BACKUP_BASE_DIR/old_enough" "$BACKUP_BASE_DIR/recent_backup"

touch -d '73 hours ago' "$BACKUP_BASE_DIR/old_enough"
touch -d '71 hours ago' "$BACKUP_BASE_DIR/recent_backup"

# shellcheck source=/dev/null
source "$repo_root/scripts/backup-all-services.sh"

log() { :; }
cleanup_local_backups

if [[ -d "$BACKUP_BASE_DIR/old_enough" ]]; then
  echo "expected backup older than 72 hours to be deleted" >&2
  exit 1
fi

if [[ ! -d "$BACKUP_BASE_DIR/recent_backup" ]]; then
  echo "expected backup newer than 72 hours to be kept" >&2
  exit 1
fi
