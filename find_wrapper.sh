#!/bin/bash
# find_wrapper.sh – transparent find replacement that routes -delete through ai-trash
#
# When an AI caller uses "find -delete", this wrapper replaces -delete with
# "-exec rm {} +" which routes through the rm_wrapper for trash protection.
# All other find invocations pass through unchanged with zero overhead.

# ── Close inherited pipe/socket fds >= 3 before any subshell (hang-prevention) ──
# See git_wrapper.sh for the full rationale: leaked caller fds (brew or AI-agent
# pipes) inherited into our $(...)/<(...) subshells make command substitution
# block forever on an EOF that never arrives. We close every inherited PIPE or
# SOCKET fd >= 3 (no fixed ceiling); regular files and devices -- including bash's
# own script descriptor, fd 255 -- are left open, since only pipes/sockets can
# deadlock a reader. Real find uses only stdio.
if [[ -d /dev/fd ]]; then
  for _aitfd in /dev/fd/*; do
    _aitfd=${_aitfd##*/}
    case "$_aitfd" in ''|*[!0-9]*) continue ;; esac
    (( _aitfd >= 3 )) || continue
    if [[ -p "/dev/fd/$_aitfd" || -S "/dev/fd/$_aitfd" ]]; then
      eval "exec ${_aitfd}>&-" 2>/dev/null || true
    fi
  done
  unset _aitfd
else
  # No /dev/fd (rare on macOS/Linux): bounded numeric close that stops below
  # bash's script descriptor (255) so we never clobber it.
  for (( _aitfd = 3; _aitfd < 250; _aitfd++ )); do
    eval "exec ${_aitfd}>&-" 2>/dev/null || true
  done
  unset _aitfd
fi

# Homebrew bypass: brew shells out to find during formula scripts and audits.
# We have nothing to trash for brew operations, and the wrapper's $(...)
# subshells can deadlock when brew's coordination FDs are inherited (see
# git_wrapper for the original incident). Short-circuit before any subshell,
# library source, or filesystem walk runs.
# HOMEBREW_BREW_FILE and HOMEBREW_LIBRARY are set only when brew itself
# invokes a subprocess. HOMEBREW_PREFIX, HOMEBREW_CELLAR, and
# HOMEBREW_REPOSITORY are exported by `brew shellenv` in every interactive
# shell on a brew host, so they are NOT brew-origin signals.
if [[ -n "${HOMEBREW_BREW_FILE:-}" || -n "${HOMEBREW_LIBRARY:-}" ]]; then
  for _f in /usr/bin/find /opt/homebrew/bin/find /bin/find; do
    [[ -x "$_f" && ! -L "$_f" ]] && exec "$_f" "$@"
  done
  _wp_self="${BASH_SOURCE[0]}"
  while [[ -L "$_wp_self" ]]; do _wp_self=$(readlink "$_wp_self"); done
  _self_dir=$(cd "$(dirname "$_wp_self")" 2>/dev/null && pwd)
  PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$_self_dir" | paste -sd: -)
  exec find "$@"
fi

# Source shared library (same directory as this script, resolve symlinks)
_WRAPPER_PATH="${BASH_SOURCE[0]}"
while [[ -L "$_WRAPPER_PATH" ]]; do _WRAPPER_PATH=$(readlink "$_WRAPPER_PATH"); done
# shellcheck source=ai-trash-lib.sh
source "$(cd "$(dirname "$_WRAPPER_PATH")" && pwd)/ai-trash-lib.sh"

# Recursion guard (belt + suspenders) — see _ait_recursion_guard in the library.
# Previously find resolved the real binary with only a basename skip and NO
# magic-byte check, so a foreign `find` script wrapper could have been re-entered;
# the shared resolver below closes that gap.
_ait_recursion_guard aitrash-find find "$@"

REAL_CMD="find"

# Resolve the real find binary via the shared, magic-byte-filtered resolver.
REAL_FIND=$(_ait_resolve_real find) || exit 127

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
