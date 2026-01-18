#!/usr/bin/env bash
# Hytale Server Updater v2.1.0-L (Linux)
# DISCLAIMER: I ***Do Not*** use Linux regularly.
#             This is just a direct port of the Powershell Logic.
#             Please report any issues on GitHub.
#             I will do my best to address them.
# --------------------------------------------------
#                   CHANGE LOG
# --------------------------------------------------
# v2.1.0-L - [Added]
#          - Linux Bash port with dry-run, staging swap, backup, and cleanup.
# v2.0.0 - [Added]
#          - Server-running check, staging & swap update, log file & summary,
#            download retries with ZIP validation, and safer failure cleanup.
# v1.0.0 - [Added]
#          - Initial release (Windows PowerShell).
#
# --------------------------------------------------
#                   USAGE GUIDE
# --------------------------------------------------
# 1. Save this script as "HytaleServerUpdater.sh" in the same folder as your Hytale server.
# 2. Open a terminal in that folder.
# 3. Make it executable: chmod +x HytaleServerUpdater.sh
#    This is only necessary the first time you run it.
# 4. Run it: ./HytaleServerUpdater.sh
# 5. Optional arguments:
#       --destination /path/to/server
#       --force-cleanup
#       --dry-run
# 6. The script will report "Update Complete" when done.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: HytaleServerUpdater.sh [--destination PATH] [--force-cleanup] [--dry-run]

Options:
  --destination, -d  Path to the Hytale server directory.
  --force-cleanup    Remove temp/staging files even if the update fails.
  --dry-run          Show what would happen without making changes.
EOF
}

destination=""
force_cleanup=0
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destination|-d)
      destination="${2:-}"
      shift 2
      ;;
    --force-cleanup)
      force_cleanup=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
log_enabled=1

dtg() {
  LC_ALL=C date +"%d%b%y-%H%M" | tr '[:lower:]' '[:upper:]'
}

log_path="${script_dir}/Update-$(dtg).log"

log() {
  local msg="$1"
  local ts
  ts="$(dtg)"
  echo "$msg"
  if [[ $log_enabled -eq 1 ]]; then
    printf '[%s] %s\n' "$ts" "$msg" >> "$log_path"
  fi
}

resolve_server_root() {
  local base_dir="$1"
  local explicit_dest="$2"

  if [[ -n "$explicit_dest" ]]; then
    realpath "$explicit_dest"
    return 0
  fi

  if [[ -f "${base_dir}/HytaleServer.jar" || -f "${base_dir}/HytaleServer.aot" ]]; then
    echo "$base_dir"
    return 0
  fi

  local found
  found="$(find "$base_dir" -maxdepth 4 -type f \( -name 'HytaleServer.jar' -o -name 'HytaleServer.aot' \) -print -quit 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    dirname "$found"
    return 0
  fi

  echo "Unable to locate Hytale server. Pass --destination to specify the server directory." >&2
  exit 1
}

server_root="$(resolve_server_root "$script_dir" "$destination")"
downloader="${script_dir}/hytale-downloader-linux-amd64"
downloader_temp=""

temp_root=""
zip_path=""
extract_dir=""
version_file="${server_root}/last_version.txt"
staging_dir="${server_root}/.update_staging"
backup_dir="${server_root}/.update_backup_$(dtg)"
success=0

if [[ $dry_run -eq 0 ]]; then
  temp_root="$(mktemp -d /tmp/hytale-update-XXXXXX)"
  zip_path="${temp_root}/game.zip"
  extract_dir="${temp_root}/game"
fi

test_server_running() {
  if pgrep -f 'HytaleServer\.jar|HytaleServer\.aot' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

cleanup() {
  if [[ $dry_run -eq 0 && ( $success -eq 1 || $force_cleanup -eq 1 ) ]]; then
    if [[ -n "$downloader_temp" && -d "$downloader_temp" ]]; then
      rm -rf "$downloader_temp"
    fi
    if [[ -n "$temp_root" && -d "$temp_root" ]]; then
      rm -rf "$temp_root"
    fi
    if [[ -d "$staging_dir" ]]; then
      rm -rf "$staging_dir"
    fi
  else
    if [[ $dry_run -eq 0 ]]; then
      log "Update failed. Temp files preserved:"
      log "Temp: $temp_root"
      log "Staging: $staging_dir"
    fi
  fi
}

trap cleanup EXIT

if test_server_running; then
  log "Hytale Server is currently running. Stop the server before updating."
  exit 1
fi

if [[ ! -x "$downloader" ]]; then
  log "Updater not found, fetching latest..."
  if [[ $dry_run -eq 1 ]]; then
    log "Downloader install skipped by user (dry run)."
  else
    downloader_temp="$(mktemp -d /tmp/hytale-downloader-XXXXXX)"
    downloader_zip="${downloader_temp}/hytale-downloader.zip"
    curl -fsSL "https://downloader.hytale.com/hytale-downloader.zip" -o "$downloader_zip"
    unzip -q "$downloader_zip" -d "$downloader_temp"
    downloaded_bin="$(find "$downloader_temp" -type f -name 'hytale-downloader-linux-amd64' -print -quit)"
    if [[ -z "$downloaded_bin" ]]; then
      echo "Downloader not found in archive." >&2
      exit 1
    fi
    cp "$downloaded_bin" "$downloader"
    chmod +x "$downloader"
  fi
fi

downloaded=0
new_version=""

if [[ $dry_run -eq 1 ]]; then
  log "Download skipped by user (dry run)."
  downloaded=1
else
  for attempt in 1 2 3; do
    log "Downloading... (attempt $attempt of 3)"
    download_log="${temp_root}/downloader.log"
    set +e
    "$downloader" -download-path "$zip_path" 2>&1 | tee "$download_log"
    exit_code=${PIPESTATUS[0]}
    set -e

    if [[ $exit_code -ne 0 ]]; then
      log "Downloader exited with code $exit_code."
      sleep 2
      continue
    fi

    if [[ ! -f "$zip_path" ]]; then
      log "Download did not produce an archive. Retrying..."
      sleep 2
      continue
    fi

    if ! unzip -t "$zip_path" >/dev/null 2>&1; then
      log "Downloaded archive is corrupt. Retrying..."
      sleep 2
      continue
    fi

    new_version="$(grep -Eo 'version[[:space:]]+[^)]+' "$download_log" | head -n 1 | sed -E 's/^version[[:space:]]+//')"
    downloaded=1
    break
  done
fi

if [[ $downloaded -ne 1 && $dry_run -eq 0 ]]; then
  echo "Download failed." >&2
  exit 1
fi

if [[ -n "$new_version" ]]; then
  old_version=""
  if [[ -f "$version_file" ]]; then
    old_version="$(cat "$version_file")"
  fi
  if [[ "$new_version" == "$old_version" ]]; then
    log "Up to date: ($new_version). Exiting."
    exit 0
  fi
fi

log "Extracting..."
if [[ $dry_run -eq 1 ]]; then
  log "Extraction skipped by user (dry run)."
else
  mkdir -p "$extract_dir"
  unzip -q "$zip_path" -d "$extract_dir"
fi

server_dir="${extract_dir}/Server"
if [[ $dry_run -eq 0 && ! -d "$server_dir" ]]; then
  echo "Server not found: $server_dir" >&2
  exit 1
fi

preserve_items=(
  "mods"
  "universe"
  "logs"
  "config.json"
  "bans.json"
  "permissions.json"
  "whitelist.json"
  "auth.enc"
  ".hytale-downloader-credentials.json"
)

should_preserve() {
  local name="$1"
  for item in "${preserve_items[@]}"; do
    if [[ "$name" == "$item" ]]; then
      return 0
    fi
  done
  return 1
}

log "Updating..."
if [[ $dry_run -eq 1 ]]; then
  log "Dry run: would stage files from $server_dir into $staging_dir, backup into $backup_dir, then swap into $server_root."
else
  if [[ -d "$staging_dir" ]]; then
    rm -rf "$staging_dir"
  fi
  mkdir -p "$staging_dir"

  shopt -s dotglob
  for item in "$server_dir"/*; do
    name="$(basename "$item")"
    if should_preserve "$name"; then
      continue
    fi
    dest="${staging_dir}/${name}"
    if [[ -d "$item" ]]; then
      cp -a "$item" "$dest"
    else
      cp -a "$item" "$dest"
    fi
  done
  shopt -u dotglob

  if [[ -d "$backup_dir" ]]; then
    rm -rf "$backup_dir"
  fi
  mkdir -p "$backup_dir"

  shopt -s dotglob
  for item in "$staging_dir"/*; do
    name="$(basename "$item")"
    dest="${server_root}/${name}"
    if [[ -e "$dest" ]]; then
      mv "$dest" "${backup_dir}/${name}"
    fi
    mv "$item" "$dest"
  done
  shopt -u dotglob
fi

assets_zip="${extract_dir}/Assets.zip"
if [[ $dry_run -eq 1 || -f "$assets_zip" ]]; then
  assets_dest_dir="$server_root"
  server_parent="$(dirname "$server_root")"
  if [[ -f "${server_root}/Assets.zip" ]]; then
    assets_dest_dir="$server_root"
  elif [[ -f "${server_parent}/Assets.zip" ]]; then
    assets_dest_dir="$server_parent"
  fi
  assets_dest="${assets_dest_dir}/Assets.zip"
  if [[ $dry_run -eq 1 ]]; then
    log "Dry run: would copy Assets.zip to $assets_dest"
  else
    cp -a "$assets_zip" "$assets_dest"
  fi
fi

if [[ -n "$new_version" ]]; then
  if [[ $dry_run -eq 1 ]]; then
    log "Dry run: would write version file $version_file"
  else
    printf '%s' "$new_version" > "$version_file"
  fi
fi

success=1
log "Update Complete."
