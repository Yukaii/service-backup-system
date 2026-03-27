#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

export HOME="$workdir/home"
mkdir -p "$HOME/Services" "$HOME/logs"
export SERVICES_DIR="$HOME/Services"
export LOG_FILE="$HOME/logs/test.log"

# shellcheck source=/dev/null
source "$repo_root/scripts/backup-all-services.sh"

calls=()
check_rclone() { :; }
check_s3_access() { :; }
check_docker() { :; }
load_ignore_list() { IGNORE_SERVICES=(); }
backup_configurations() { :; }
backup_service() { :; }
upload_to_s3() { :; }
generate_report() { :; }
setup_directories() { calls+=("setup_directories"); }
cleanup_local_backups() { calls+=("cleanup_local_backups"); }
log() { :; }

main

if [[ ${#calls[@]} -lt 2 ]]; then
  echo "expected both cleanup and setup to run, got: ${calls[*]-<none>}" >&2
  exit 1
fi

if [[ "${calls[0]}" != "cleanup_local_backups" ]]; then
  echo "expected cleanup_local_backups before setup_directories, got: ${calls[*]}" >&2
  exit 1
fi
