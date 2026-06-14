#!/bin/bash
# check-path-shadows.sh — detect (and where safe, auto-fix) duplicate command
# wrappers on PATH that could re-introduce the 2026-06-14 wrapper-recursion spin.
#
# The bug class (see memory/git_wrapper_thundering_herd.md): two or more
# script-based wrappers shadow the same command on PATH. If any of them resolves
# "the real command" into another wrapper, they re-exec each other unbounded and
# pin a CPU core. A separate incident (stale ~/bin/rsync) showed the same risk
# arrives not as a code change but as a NEW FILE appearing on disk later, ahead
# of the canonical install on PATH.
#
# A log nobody reads is useless, so this tool splits findings by certainty:
#   CERTAIN + SAFE  -> auto-quarantine. A duplicate that is a fingerprinted
#                      ai-trash wrapper copy outside the canonical install dir
#                      (exactly the stale ~/bin/rsync case) is moved aside. The
#                      user never has to act; it is auto-recovered.
#   UNCERTAIN       -> cannot be safely auto-fixed (a foreign, UNGUARDED script
#                      shadowing the command). We drop a flag file that makes
#                      every new shell print a sticky banner until it is gone.
#                      The banner self-clears: the next run deletes the flag when
#                      PATH is clean again.
# A JSONL line per run is appended as an audit trail only — never the
# notification mechanism.
#
# Two coexisting GUARDED script wrappers (e.g. the ai-trash git wrapper plus the
# ~/.claude/bin/git shim, both carrying _ait_recursion_guard) are NOT flagged:
# the belt+suspenders guard makes their coexistence safe by construction.
#
# Usage:
#   check-path-shadows.sh            scan, auto-fix safe cases, set/clear banner
#   check-path-shadows.sh --dry-run  report only; touch nothing (used by tests)
#
# Exit: 0 clean, 1 uncertain case surfaced (banner set), 2 auto-fix performed.
# Env:
#   AI_TRASH_INSTALL_DIR   canonical wrapper install dir (default /usr/local/bin)
#   AI_TRASH_STATE_DIR     where the banner flag + log live (default ~/.ai-trash)
#   AI_TRASH_SHADOW_CMDS   space-separated command list to check (default below)

set -uo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

INSTALL_DIR="${AI_TRASH_INSTALL_DIR:-/usr/local/bin}"
# Normalize to the physical path so the canonical-dir comparison below matches
# the cd/pwd-normalized PATH dirs (avoids /var vs /private/var false mismatches).
INSTALL_DIR=$(cd "$INSTALL_DIR" 2>/dev/null && pwd || printf '%s' "$INSTALL_DIR")
STATE_DIR="${AI_TRASH_STATE_DIR:-$HOME/.ai-trash}"
BANNER_FLAG="$STATE_DIR/path-shadow-warning"
AUDIT_LOG="$STATE_DIR/path-shadow-log.jsonl"
QUARANTINE_DIR="$HOME/.ai-trash-stale-backup"

# Commands ai-trash wraps — the recursion-risk surface. We deliberately do NOT
# scan all of PATH: language-runtime shims (asdf/mise/pyenv) legitimately put a
# foreign script ahead of node/python/ruby, which would be false positives. The
# wrapped utilities below are not version-managed, so a foreign script shadowing
# one of them is genuinely worth surfacing.
DEFAULT_CMDS="git rm rmdir unlink mv find rsync"
read -ra CMDS <<<"${AI_TRASH_SHADOW_CMDS:-$DEFAULT_CMDS}"

# ── Pure helpers (no side effects) ─────────────────────────────────────
# First two bytes of a file (for #! detection). Empty on unreadable/binary.
_first2() { LC_ALL=C head -c2 -- "$1" 2>/dev/null; }

# Resolve a symlink chain to its final target (handles relative links).
_resolve_chain() {
  local p="$1" t
  while [[ -L "$p" ]]; do
    t=$(readlink -- "$p") || break
    case "$t" in
      /*) p="$t" ;;
      *)  p="$(cd "$(dirname -- "$p")" 2>/dev/null && pwd)/$t" ;;
    esac
  done
  printf '%s' "$p"
}

_is_script()  { [[ "$(_first2 "$1")" == '#!' ]]; }
# A fingerprinted ai-trash wrapper: resolves to a *_wrapper.sh that mentions
# ai-trash. Strong enough to never match a foreign tool by accident.
_is_aitrash() {
  local resolved="$1"
  [[ "${resolved##*/}" == *_wrapper.sh ]] && grep -q "ai-trash" -- "$resolved" 2>/dev/null
}
# Carries the recursion guard. True for the ai-trash wrappers (via the shared
# _ait_recursion_guard call) AND the ~/.claude/bin/git shim, which carries the
# same belt+suspenders inline keyed on AI_GIT_WRAPPER_CHAIN. Either marker counts.
_is_guarded() { grep -qE "_ait_recursion_guard|AI_GIT_WRAPPER_CHAIN" -- "$1" 2>/dev/null; }

# ── Collect ordered, de-duplicated PATH dirs ───────────────────────────
_path_dirs() {
  local IFS=: d seen=":"
  for d in $PATH; do
    [[ -z "$d" ]] && d="."
    local abs
    abs=$(cd "$d" 2>/dev/null && pwd) || continue
    case "$seen" in *":$abs:"*) continue ;; esac
    seen="$seen$abs:"
    printf '%s\n' "$abs"
  done
}

# Read into an array without mapfile (absent in macOS's stock /bin/bash 3.2,
# which is what the launchd job and the #! shebang actually run under).
PATH_DIRS=()
while IFS= read -r _pd; do PATH_DIRS+=("$_pd"); done < <(_path_dirs)

# ── Scan ───────────────────────────────────────────────────────────────
# Accumulators across all commands.
declare -a QUARANTINE_TARGETS=()   # "cmd<TAB>path<TAB>resolved" for auto-fix
declare -a SURFACE_FINDINGS=()     # human-readable lines for the banner
declare -a REPORT_LINES=()         # full dry-run / stdout report

_scan_command() {
  local cmd="$1"
  local -a hits=()
  local dir p resolved
  for dir in "${PATH_DIRS[@]}"; do
    p="$dir/$cmd"
    [[ -x "$p" && ! -d "$p" ]] || continue
    hits+=("$p")
  done
  (( ${#hits[@]} == 0 )) && return 0

  # Classify each hit. Count SCRIPT instances and, among them, how many are
  # unguarded — but exclude instances we are about to quarantine (stale ai-trash
  # copies), so an auto-fixed duplicate is never also surfaced.
  local live_scripts=0 live_unguarded=0
  for p in "${hits[@]}"; do
    resolved=$(_resolve_chain "$p")
    local kind="binary" tag="" quarantine=false guarded=false
    if _is_script "$p"; then
      kind="script"
      if _is_aitrash "$resolved"; then
        guarded=true   # ai-trash wrappers carry the shared guard
        if [[ "$(dirname -- "$p")" != "$INSTALL_DIR" ]]; then
          QUARANTINE_TARGETS+=("$cmd	$p	$resolved")
          tag="ai-trash-wrapper(STALE@$(dirname -- "$p"))"; quarantine=true
        else
          tag="ai-trash-wrapper(canonical)"
        fi
      elif _is_guarded "$resolved"; then
        tag="guarded-foreign-wrapper"; guarded=true   # e.g. ~/.claude/bin/git shim
      else
        tag="UNGUARDED-foreign-script"
      fi
      if [[ "$quarantine" == false ]]; then
        live_scripts=$((live_scripts+1))
        [[ "$guarded" == false ]] && live_unguarded=$((live_unguarded+1))
      fi
    fi
    REPORT_LINES+=("  $cmd: $p [$kind${tag:+, $tag}] -> $resolved")
  done

  # Recursion hazard = TWO OR MORE script wrappers stacked on the same command
  # with at least one UNGUARDED participant (the condition under which two
  # wrappers can re-exec each other). A lone foreign wrapper, or multiple
  # wrappers that all carry the guard, is safe by construction and not surfaced.
  if (( live_scripts >= 2 && live_unguarded >= 1 )); then
    SURFACE_FINDINGS+=("$cmd: $live_scripts script wrappers shadow '$cmd' on PATH, $live_unguarded without a recursion guard (recursion hazard)")
  fi
}

for c in "${CMDS[@]}"; do _scan_command "$c"; done

# ── Report (always) ────────────────────────────────────────────────────
if (( ${#REPORT_LINES[@]} > 0 )); then
  printf '%s\n' "PATH wrapper scan (canonical install dir: $INSTALL_DIR):"
  printf '%s\n' "${REPORT_LINES[@]}"
fi

# ── Act ────────────────────────────────────────────────────────────────
rc=0
quarantined=0
surfaced=${#SURFACE_FINDINGS[@]}

_audit() {
  # Append one JSONL line. Best-effort; never blocks the run.
  local q="$1" s="$2"
  [[ "$DRY_RUN" == true ]] && return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '{"ts":"%s","quarantined":%s,"surfaced":%s,"install_dir":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$q" "$s" "$INSTALL_DIR" \
    >>"$AUDIT_LOG" 2>/dev/null || true
}

# Auto-fix the certain+safe cases: quarantine stale ai-trash wrapper copies.
if (( ${#QUARANTINE_TARGETS[@]} > 0 )); then
  for entry in ${QUARANTINE_TARGETS[@]+"${QUARANTINE_TARGETS[@]}"}; do
    IFS=$'\t' read -r qcmd qpath qresolved <<<"$entry"
    if [[ "$DRY_RUN" == true ]]; then
      printf 'WOULD QUARANTINE (stale ai-trash %s): %s -> %s\n' "$qcmd" "$qpath" "$qresolved"
      quarantined=$((quarantined+1))
      continue
    fi
    if ! mkdir -p "$QUARANTINE_DIR" 2>/dev/null; then
      SURFACE_FINDINGS+=("$qcmd: stale wrapper at $qpath could not be quarantined (no $QUARANTINE_DIR)")
      continue
    fi
    stamp=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || printf 'unknown')
    ok=true
    # Move the PATH entry itself, and its resolved *_wrapper.sh sibling if it
    # lives in the same stale dir (the canonical pair: `rsync` -> `rsync_wrapper.sh`).
    for f in "$qpath" "$qresolved"; do
      [[ -e "$f" || -L "$f" ]] || continue
      [[ "$(dirname -- "$f")" == "$INSTALL_DIR" ]] && continue   # never touch canonical
      if ! mv -f -- "$f" "$QUARANTINE_DIR/${f##*/}.$stamp.stale" 2>/dev/null; then
        ok=false
      fi
    done
    if [[ "$ok" == true ]]; then
      printf 'QUARANTINED stale ai-trash %s wrapper: %s (moved to %s)\n' "$qcmd" "$qpath" "$QUARANTINE_DIR"
      quarantined=$((quarantined+1))
    else
      SURFACE_FINDINGS+=("$qcmd: stale wrapper at $qpath could not be moved (permission?)")
    fi
  done
fi

# Surface the uncertain cases via the sticky banner flag (self-clearing).
surfaced=${#SURFACE_FINDINGS[@]}
if [[ "$DRY_RUN" == true ]]; then
  if (( surfaced > 0 )); then
    printf 'WOULD SURFACE (banner):\n'
    printf '  - %s\n' "${SURFACE_FINDINGS[@]}"
    rc=1
  fi
  (( quarantined > 0 )) && rc=2
  exit "$rc"
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true
if (( surfaced > 0 )); then
  {
    printf 'ai-trash: PATH shadow warning (run check-path-shadows.sh for detail)\n'
    printf '  %s\n' "${SURFACE_FINDINGS[@]}"
    printf 'Resolve the above, then this banner clears automatically.\n'
  } > "$BANNER_FLAG" 2>/dev/null || true
  rc=1
else
  # Clean -> self-clear the banner.
  rm -f "$BANNER_FLAG" 2>/dev/null || true
fi
(( quarantined > 0 )) && rc=2

_audit "$quarantined" "$surfaced"
exit "$rc"
