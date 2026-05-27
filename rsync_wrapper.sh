#!/bin/bash
# rsync_wrapper.sh – transparent rsync replacement that preserves AI rsync changes
#
# For AI callers, rsync commands that can delete destination files are run with
# rsync's backup mechanism enabled. Backups are imported into ai-trash after
# rsync exits, so overwritten and deleted destination files can be restored.

# Homebrew bypass: brew shells out to rsync during fetch/extract. We have
# nothing to trash for brew operations, and the wrapper's $(...) subshells
# can deadlock when brew's coordination FDs are inherited (see git_wrapper
# for the original incident). Short-circuit before any subshell, library
# source, or filesystem walk runs.
# HOMEBREW_BREW_FILE and HOMEBREW_LIBRARY are set only when brew itself
# invokes a subprocess. HOMEBREW_PREFIX, HOMEBREW_CELLAR, and
# HOMEBREW_REPOSITORY are exported by `brew shellenv` in every interactive
# shell on a brew host, so they are NOT brew-origin signals.
if [[ -n "${HOMEBREW_BREW_FILE:-}" || -n "${HOMEBREW_LIBRARY:-}" ]]; then
  for _r in /opt/homebrew/bin/rsync /usr/local/bin/rsync /usr/bin/rsync /bin/rsync; do
    [[ -x "$_r" && ! -L "$_r" ]] && exec "$_r" "$@"
  done
  _wp_self="${BASH_SOURCE[0]}"
  while [[ -L "$_wp_self" ]]; do _wp_self=$(readlink "$_wp_self"); done
  _self_dir=$(cd "$(dirname "$_wp_self")" 2>/dev/null && pwd)
  PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$_self_dir" | paste -sd: -)
  exec rsync "$@"
fi

# Source shared library (same directory as this script, resolve symlinks)
_WRAPPER_PATH="${BASH_SOURCE[0]}"
while [[ -L "$_WRAPPER_PATH" ]]; do _WRAPPER_PATH=$(readlink "$_WRAPPER_PATH"); done
# shellcheck source=ai-trash-lib.sh
source "$(cd "$(dirname "$_WRAPPER_PATH")" && pwd)/ai-trash-lib.sh"

REAL_CMD="rsync"

_find_real_rsync() {
  local wrapper_dir _wp="${BASH_SOURCE[0]}"
  while [[ -L "$_wp" ]]; do _wp=$(readlink "$_wp"); done
  wrapper_dir=$(cd "$(dirname "$_wp")" && pwd)

  local IFS=:
  for dir in $PATH; do
    local resolved
    resolved=$(cd "$dir" 2>/dev/null && pwd) || continue
    [[ "$resolved" == "$wrapper_dir" ]] && continue
    if [[ -x "$dir/rsync" ]]; then
      local candidate="$dir/rsync"
      while [[ -L "$candidate" ]]; do candidate=$(readlink "$candidate"); done
      [[ "$(basename "$candidate")" == "rsync_wrapper.sh" ]] && continue
      printf '%s' "$dir/rsync"
      return
    fi
  done

  # Resolve symlinks and skip self so we never return our own wrapper
  # (which would cause infinite re-entry).
  for r in /opt/homebrew/bin/rsync /usr/local/bin/rsync /usr/bin/rsync /bin/rsync; do
    [[ -x "$r" ]] || continue
    local candidate="$r"
    while [[ -L "$candidate" ]]; do candidate=$(readlink "$candidate"); done
    [[ "$(basename "$candidate")" == "rsync_wrapper.sh" ]] && continue
    printf '%s' "$r"; return
  done

  echo "ai-trash rsync wrapper: cannot find real rsync binary" >&2
  exit 127
}

_rsync_option_takes_value() {
  case "$1" in
    -e|--rsh|--rsync-path|--backup-dir|--suffix|--temp-dir|--partial-dir| \
    --compare-dest|--copy-dest|--link-dest|--files-from|--exclude-from| \
    --include-from|--filter|--out-format|--log-file|--log-file-format| \
    --password-file|--chmod|--chown|--usermap|--groupmap|--bwlimit| \
    --max-size|--min-size|--contimeout|--timeout|--info|--debug)
      return 0 ;;
  esac
  return 1
}

_rsync_operands() {
  local after_dd=false skip_next=false arg
  for arg in "$@"; do
    if [[ "$skip_next" == true ]]; then
      skip_next=false
      continue
    fi
    if [[ "$after_dd" == true ]]; then
      printf '%s\n' "$arg"
      continue
    fi
    case "$arg" in
      --)
        after_dd=true ;;
      --*=*)
        ;;
      --*)
        _rsync_option_takes_value "$arg" && skip_next=true ;;
      -e)
        skip_next=true ;;
      -*)
        ;;
      *)
        printf '%s\n' "$arg" ;;
    esac
  done
}

_rsync_has_delete_flag() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --delete|--delete-*)
        return 0 ;;
    esac
  done
  return 1
}

_rsync_has_user_backup_behavior() {
  local arg skip_next=false
  for arg in "$@"; do
    if [[ "$skip_next" == true ]]; then
      skip_next=false
      continue
    fi
    case "$arg" in
      --backup|--no-backup|--backup-dir|--backup-dir=*|-b|-[!-]*b*)
        return 0 ;;
      --)
        return 1 ;;
    esac
    [[ "$arg" == "--backup-dir" ]] && skip_next=true
  done
  return 1
}

_rsync_is_remote_path() {
  local path="$1"
  [[ "$path" == rsync://* || "$path" == *::* ]] && return 0
  [[ "$path" == *:* && "$path" != /* ]] && return 0
  return 1
}

_rsync_abs_path() {
  local path="$1" dir base abs_dir
  if realpath "$path" 2>/dev/null; then
    return 0
  fi
  dir=$(dirname "$path")
  base=$(basename "$path")
  abs_dir=$(cd "$dir" 2>/dev/null && pwd) || return 1
  printf '%s/%s\n' "$abs_dir" "$base"
}

REAL_RSYNC=$(_find_real_rsync)

# openrsync (Apple's BSD clone, default on macOS 15+) is stricter than GNU
# rsync and fails with "fchownat: Operation not permitted" when --backup-dir
# is used with -a, since it tries to preserve ownership on backup files.
# We can't selectively disable -o for the backup copy only, so pass through.
_rsync_is_openrsync() {
  "$REAL_RSYNC" --version 2>&1 | head -1 | grep -qi openrsync
}

# ─── Guards ────────────────────────────────────────────────────────────
if [[ -z "$HOME" || "$HOME" == "/var/root" ]]; then
  exec "$REAL_RSYNC" "$@"
fi

if [[ -n "${APP_SANDBOX_CONTAINER_ID:-}" ]]; then
  exec "$REAL_RSYNC" "$@"
fi

if [[ "${RSYNC_PROTECTION:-true}" != true ]]; then
  exec "$REAL_RSYNC" "$@"
fi

if _rsync_is_openrsync; then
  exec "$REAL_RSYNC" "$@"
fi

if ! _is_ai_process; then
  exec "$REAL_RSYNC" "$@"
fi

if _rsync_has_user_backup_behavior "$@"; then
  exec "$REAL_RSYNC" "$@"
fi

if [[ "${RSYNC_PROTECT_ALL_LOCAL:-false}" != true ]] && ! _rsync_has_delete_flag "$@"; then
  exec "$REAL_RSYNC" "$@"
fi

OPERANDS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && OPERANDS+=("$line")
done < <(_rsync_operands "$@")

if [[ ${#OPERANDS[@]} -lt 2 ]]; then
  exec "$REAL_RSYNC" "$@"
fi

DEST_ARG="${OPERANDS[$(( ${#OPERANDS[@]} - 1 ))]}"
if _rsync_is_remote_path "$DEST_ARG"; then
  exec "$REAL_RSYNC" "$@"
fi

DEST_ABS=$(_rsync_abs_path "$DEST_ARG") || exec "$REAL_RSYNC" "$@"
DEST_IS_DIR=false
if [[ ${#OPERANDS[@]} -gt 2 || "$DEST_ARG" == */ || -d "$DEST_ARG" ]]; then
  DEST_IS_DIR=true
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ).$$.$RANDOM"
STAGING_BASE="${XDG_CACHE_HOME:-$HOME/.cache}/ai-trash/rsync-staging"
STAGING_DIR="$STAGING_BASE/$RUN_ID"
SUFFIX=".ai-trash-rsync-backup-$RUN_ID"

mkdir -p "$STAGING_DIR" 2>/dev/null || exec "$REAL_RSYNC" "$@"

"$REAL_RSYNC" "$@" --backup --backup-dir="$STAGING_DIR" --suffix="$SUFFIX"
rsync_status=$?

import_rsync_backup_dir_to_ai_trash "$STAGING_DIR" "$DEST_ABS" "$DEST_IS_DIR" "$SUFFIX"
import_status=$?

if [[ $rsync_status -ne 0 ]]; then
  exit "$rsync_status"
fi
exit "$import_status"
