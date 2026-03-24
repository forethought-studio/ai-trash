#!/bin/bash
# find_wrapper.sh – transparent find replacement that routes -delete through ai-trash
#
# When an AI caller uses "find -delete", this wrapper replaces -delete with
# "-exec rm {} +" which routes through the rm_wrapper for trash protection.
# All other find invocations pass through unchanged with zero overhead.

# Source shared library (same directory as this script, resolve symlinks)
_WRAPPER_PATH="${BASH_SOURCE[0]}"
while [[ -L "$_WRAPPER_PATH" ]]; do _WRAPPER_PATH=$(readlink "$_WRAPPER_PATH"); done
# shellcheck source=ai-trash-lib.sh
source "$(cd "$(dirname "$_WRAPPER_PATH")" && pwd)/ai-trash-lib.sh"

REAL_CMD="find"

# ─── Find the real find binary (skip ourselves in PATH) ────────────────
_find_real_find() {
  local wrapper_dir _wp="${BASH_SOURCE[0]}"
  while [[ -L "$_wp" ]]; do _wp=$(readlink "$_wp"); done
  wrapper_dir=$(cd "$(dirname "$_wp")" && pwd)

  local IFS=:
  for dir in $PATH; do
    local resolved
    resolved=$(cd "$dir" 2>/dev/null && pwd) || continue
    [[ "$resolved" == "$wrapper_dir" ]] && continue
    if [[ -x "$dir/find" ]]; then
      # Skip if this is a symlink that resolves to our wrapper
      local candidate="$dir/find"
      while [[ -L "$candidate" ]]; do candidate=$(readlink "$candidate"); done
      [[ "$(basename "$candidate")" == "find_wrapper.sh" ]] && continue
      printf '%s' "$dir/find"
      return
    fi
  done

  # Fallback to common locations
  for f in /usr/bin/find /bin/find; do
    [[ -x "$f" ]] && { printf '%s' "$f"; return; }
  done

  echo "ai-trash find wrapper: cannot find real find binary" >&2
  exit 127
}

REAL_FIND=$(_find_real_find)

# ─── Guards ────────────────────────────────────────────────────────────
# Non-user contexts: instant passthrough
if [[ -z "$HOME" || "$HOME" == "/var/root" ]]; then
  exec "$REAL_FIND" "$@"
fi

# Guard: macOS App Sandbox — pass through to real binary
if [[ -n "${APP_SANDBOX_CONTAINER_ID:-}" ]]; then
  exec "$REAL_FIND" "$@"
fi

# Feature toggle
if [[ "${FIND_PROTECTION:-true}" != true ]]; then
  exec "$REAL_FIND" "$@"
fi

# Non-AI callers: instant passthrough
if ! _is_ai_process; then
  exec "$REAL_FIND" "$@"
fi

# ─── Check if -delete is used ─────────────────────────────────────────
has_delete=false
for arg in "$@"; do
  [[ "$arg" == "-delete" ]] && { has_delete=true; break; }
done

# No -delete: instant passthrough
if [[ "$has_delete" == false ]]; then
  exec "$REAL_FIND" "$@"
fi

# ─── Replace -delete with -exec rm {} + ───────────────────────────────
# This routes deletions through the rm wrapper, which provides ai-trash
# protection. The rm in PATH is our rm_wrapper.sh.
new_args=()
for arg in "$@"; do
  if [[ "$arg" == "-delete" ]]; then
    # Find the rm wrapper in the same directory as us
    _frm="${BASH_SOURCE[0]}"
    while [[ -L "$_frm" ]]; do _frm=$(readlink "$_frm"); done
    local_rm="$(cd "$(dirname "$_frm")" && pwd)/rm"
    if [[ -x "$local_rm" ]]; then
      new_args+=("-exec" "$local_rm" "{}" "+")
    else
      # Fallback: use rm from PATH (should be our wrapper)
      new_args+=("-exec" "rm" "{}" "+")
    fi
  else
    new_args+=("$arg")
  fi
done

exec "$REAL_FIND" "${new_args[@]}"
