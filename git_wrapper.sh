#!/bin/bash
# git_wrapper.sh – transparent git replacement that snapshots files before destructive operations
#
# "Snapshot Before Execute": for AI callers running destructive git subcommands,
# copy affected files to ai-trash before letting git run normally.
# Non-AI callers and non-destructive subcommands pass through instantly.

# ── Close inherited pipe/socket fds >= 3 (hang-prevention, must run first) ──
# When this wrapper is invoked with extra fds open (brew's coordination fd, or
# an AI agent's stdout/stderr capture pipes), those fds leak into our $(...) and
# <(...) subshells. A forked child keeps the pipe's write end open, so the reader
# never sees EOF and command substitution blocks forever -- the historical "git
# hangs" failure. We close every inherited PIPE or SOCKET fd >= 3 up front, which
# makes that hang class impossible by construction with no fixed ceiling.
# We deliberately test the fd type instead of capping at a fixed number: only
# pipes and sockets can deadlock a reader. Regular files and devices are left
# open because (a) bash's own script descriptor (typically fd 255) is a regular
# file and MUST stay open for the wrapper to keep running, and (b) a regular file
# always reports EOF, so it can never cause this hang. Real git uses only stdio.
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

# Recursion guard runs just after the shared library is sourced, below — it
# needs _ait_recursion_guard from ai-trash-lib.sh. The guard is safe there
# because nothing between the fd-close above and that point invokes git: the
# Homebrew bypass execs a real binary, and sourcing the library only runs
# non-git subprocesses. See _ait_recursion_guard for the belt+suspenders design.

# Homebrew bypass: brew shells out to git for analytics/config checks many
# times per invocation. We have nothing to snapshot for brew operations, and
# the wrapper has historically hung on this path when brew's coordination
# file descriptors are inherited into the wrapper's $(...) subshells (see
# memory/git_wrapper_brew_hang.md). Short-circuit before any subshell, ps,
# or filesystem walk runs.
# HOMEBREW_PREFIX, HOMEBREW_CELLAR, and HOMEBREW_REPOSITORY are exported by
# `brew shellenv` for every interactive shell on a brew-installed host, so
# they are NOT brew-origin signals. HOMEBREW_BREW_FILE and HOMEBREW_LIBRARY
# are set only when brew itself invokes a subprocess, so they reliably
# identify a brew-originated call.
if [[ -n "${HOMEBREW_BREW_FILE:-}" || -n "${HOMEBREW_LIBRARY:-}" ]]; then
  for _g in /usr/bin/git /opt/homebrew/bin/git /usr/local/Cellar/git/*/bin/git; do
    [[ -x "$_g" && ! -L "$_g" ]] && exec "$_g" "$@"
  done
  # Last resort: strip the wrapper's own dir from PATH and try git.
  _wp_self="${BASH_SOURCE[0]}"
  while [[ -L "$_wp_self" ]]; do _wp_self=$(readlink "$_wp_self"); done
  _self_dir=$(cd "$(dirname "$_wp_self")" 2>/dev/null && pwd)
  PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$_self_dir" | grep -vxF /usr/local/bin | paste -sd: -)
  exec git "$@"
fi

# Source shared library (same directory as this script, resolve symlinks)
_WRAPPER_PATH="${BASH_SOURCE[0]}"
while [[ -L "$_WRAPPER_PATH" ]]; do _WRAPPER_PATH=$(readlink "$_WRAPPER_PATH"); done
# shellcheck source=ai-trash-lib.sh
source "$(cd "$(dirname "$_WRAPPER_PATH")" && pwd)/ai-trash-lib.sh"

# Recursion guard (belt + suspenders) — see _ait_recursion_guard in the library.
# Tag "aitrash" pairs with the shim's "shim" tag so the two break each other's
# loops. This is the first point that could exec git, so the guard belongs here.
_ait_recursion_guard aitrash git "$@"

REAL_CMD="git"

# Resolve the real git binary via the shared, magic-byte-filtered resolver.
REAL_GIT=$(_ait_resolve_real git) || exit 127

# ─── Guards ────────────────────────────────────────────────────────────
# Non-user contexts: instant passthrough
if [[ -z "$HOME" || "$HOME" == "/var/root" ]]; then
  exec "$REAL_GIT" "$@"
fi

# Guard: macOS App Sandbox — pass through to real binary
if [[ -n "${APP_SANDBOX_CONTAINER_ID:-}" ]]; then
  exec "$REAL_GIT" "$@"
fi

# Feature toggle
if [[ "${GIT_PROTECTION:-true}" != true ]]; then
  exec "$REAL_GIT" "$@"
fi

# (AI-caller detection deliberately deferred until AFTER the subcommand is
#  classified, see below. It walks the process tree with `ps -A`, which must
#  never run on the non-destructive hot path.)

# ─── Parse git global options to find the subcommand ───────────────────
_get_git_subcommand() {
  local skip_next=false
  for arg in "$@"; do
    if [[ "$skip_next" == true ]]; then
      skip_next=false
      continue
    fi
    case "$arg" in
      -C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--exec-path)
        skip_next=true; continue ;;
      --git-dir=*|--work-tree=*|-c=*|--namespace=*|--exec-path=*) continue ;;
      --bare|--no-pager|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--no-optional-locks)
        continue ;;
      -*) continue ;;
      *) printf '%s' "$arg"; return ;;
    esac
  done
}

# Get everything after the subcommand
_get_subcommand_args() {
  local found_subcmd=false skip_next=false
  for arg in "$@"; do
    if [[ "$skip_next" == true ]]; then
      skip_next=false; continue
    fi
    if [[ "$found_subcmd" == true ]]; then
      printf '%s\n' "$arg"
      continue
    fi
    case "$arg" in
      -C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--exec-path)
        skip_next=true; continue ;;
      --git-dir=*|--work-tree=*|-c=*|--namespace=*|--exec-path=*) continue ;;
      --bare|--no-pager|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--no-optional-locks)
        continue ;;
      -*) continue ;;
      *) found_subcmd=true ;;
    esac
  done
}

# Get global args before the subcommand (e.g., -C /path, --no-pager)
_get_global_args() {
  local skip_next=false
  for arg in "$@"; do
    if [[ "$skip_next" == true ]]; then
      printf '%s\n' "$arg"
      skip_next=false
      continue
    fi
    case "$arg" in
      -C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--exec-path)
        printf '%s\n' "$arg"; skip_next=true; continue ;;
      --git-dir=*|--work-tree=*|-c=*|--namespace=*|--exec-path=*)
        printf '%s\n' "$arg"; continue ;;
      --bare|--no-pager|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--no-optional-locks)
        printf '%s\n' "$arg"; continue ;;
      -*) continue ;;
      *) return ;;  # Hit subcommand, stop
    esac
  done
}

SUBCMD=$(_get_git_subcommand "$@")

# ─── Hot path: classify BEFORE any process inspection ──────────────────
# The overwhelming majority of git calls are non-destructive (status, log,
# diff, rev-parse, config, add, commit, fetch, clone, ...). They pass straight
# through to real git here, WITHOUT walking the process tree. The `ps -A` walk
# in _is_ai_process is O(all processes); running it on every git call (rather
# than only the rare destructive ones) was the root cause of the load/hang
# incidents, especially under an exec-scanning EDR. Only the small destructive
# set falls through to AI detection + snapshotting.
case "$SUBCMD" in
  clean|checkout|restore|reset|stash|branch|push|filter-repo) ;; # maybe destructive, handled below
  *) exec "$REAL_GIT" "$@" ;;
esac

# ─── AI-caller detection: only reached for the destructive subcommand set ──
# We only snapshot for AI-driven destructive operations. Non-AI callers (human
# shells, build tools) pass through untouched.
if ! _is_ai_process; then
  exec "$REAL_GIT" "$@"
fi

# ─── Read subcommand args into array ──────────────────────────────────
SUB_ARGS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && SUB_ARGS+=("$line")
done < <(_get_subcommand_args "$@")

# ─── Read global args (before subcommand) into array ─────────────────
GLOBAL_ARGS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && GLOBAL_ARGS+=("$line")
done < <(_get_global_args "$@")

# ─── Get repo toplevel for resolving relative paths ────────────────────
TOPLEVEL=$("$REAL_GIT" "${GLOBAL_ARGS[@]}" rev-parse --show-toplevel 2>/dev/null) || {
  # Not in a git repo — passthrough
  exec "$REAL_GIT" "$@"
}

# ─── Helper: snapshot a list of repo-relative files ────────────────────
_snapshot_files() {
  local -a files=()
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local full="$TOPLEVEL/$f"
    [[ -e "$full" || -L "$full" ]] && files+=("$full")
  done

  if [[ ${#files[@]} -gt 0 ]]; then
    snapshot_to_ai_trash "${files[@]}"
  fi
}

# ─── Subcommand handlers ──────────────────────────────────────────────

case "$SUBCMD" in

  # ── git clean ──────────────────────────────────────────────────────
  clean)
    # Only intercept when -f is present (required for actual deletion)
    has_force_flag=false
    for arg in "${SUB_ARGS[@]}"; do
      case "$arg" in
        -*f*|-*fd*|-*fx*|-*fdx*|-*fxd*) has_force_flag=true ;;
        --force) has_force_flag=true ;;
      esac
    done

    if [[ "$has_force_flag" == true ]]; then
      # Dry-run to find what would be cleaned (LC_ALL=C forces English output)
      dry_output=$(LC_ALL=C "$REAL_GIT" "${GLOBAL_ARGS[@]}" clean -n "${SUB_ARGS[@]}" 2>/dev/null) || true
      if [[ -n "$dry_output" ]]; then
        echo "$dry_output" | sed -n 's/^Would remove //p' | while IFS= read -r f; do
          [[ -z "$f" ]] && continue
          # git clean -n outputs paths relative to the repo root
          full="$TOPLEVEL/$f"
          [[ -e "$full" || -L "$full" ]] && snapshot_to_ai_trash "$full"
        done
      fi
    fi

    exec "$REAL_GIT" "$@"
    ;;

  # ── git checkout ───────────────────────────────────────────────────
  checkout)
    # Destructive patterns:
    #   git checkout -- <path>...
    #   git checkout . (discard all changes)
    #   git checkout <path> (when path exists as file, not branch)
    # Conservative: only intercept when -- is present, or arg is "."
    has_dd=false
    has_dot=false
    for arg in "${SUB_ARGS[@]}"; do
      [[ "$arg" == "--" ]] && has_dd=true
      [[ "$arg" == "." && "$has_dd" == true ]] && has_dot=true
    done

    # Also catch: git checkout . (no --)
    if [[ ${#SUB_ARGS[@]} -eq 1 && "${SUB_ARGS[0]}" == "." ]]; then
      has_dot=true
    fi

    if [[ "$has_dd" == true || "$has_dot" == true ]]; then
      # Snapshot modified working-tree files
      "$REAL_GIT" "${GLOBAL_ARGS[@]}" diff --name-only 2>/dev/null | _snapshot_files
    fi

    exec "$REAL_GIT" "$@"
    ;;

  # ── git restore ────────────────────────────────────────────────────
  restore)
    # Destructive when restoring working tree (default or --worktree)
    # Not destructive when only --staged
    has_staged_only=false
    has_worktree=false
    has_source=false
    for arg in "${SUB_ARGS[@]}"; do
      case "$arg" in
        --staged|-S) has_staged_only=true ;;
        --worktree|-W) has_worktree=true ;;
        --source|--source=*|-s) has_source=true ;;
      esac
    done

    # If --worktree is also specified alongside --staged, it IS destructive
    if [[ "$has_staged_only" == true && "$has_worktree" == false ]]; then
      exec "$REAL_GIT" "$@"
    fi

    # Snapshot modified working-tree files (unstaged changes)
    "$REAL_GIT" "${GLOBAL_ARGS[@]}" diff --name-only 2>/dev/null | _snapshot_files
    # Also snapshot staged changes (visible via --cached)
    "$REAL_GIT" "${GLOBAL_ARGS[@]}" diff --cached --name-only 2>/dev/null | _snapshot_files

    exec "$REAL_GIT" "$@"
    ;;

  # ── git reset ──────────────────────────────────────────────────────
  reset)
    # Destructive modes: --hard, --merge, --keep (all can overwrite working tree)
    has_destructive_reset=false
    reset_mode=""
    for arg in "${SUB_ARGS[@]}"; do
      case "$arg" in
        --hard)  has_destructive_reset=true; reset_mode="hard" ;;
        --merge) has_destructive_reset=true; reset_mode="merge" ;;
        --keep)  has_destructive_reset=true; reset_mode="keep" ;;
      esac
    done

    if [[ "$has_destructive_reset" == true ]]; then
      # Capture uncommitted state as a temporary stash object
      stash_sha=$("$REAL_GIT" "${GLOBAL_ARGS[@]}" stash create 2>/dev/null) || true
      if [[ -n "$stash_sha" ]]; then
        patch=$("$REAL_GIT" "${GLOBAL_ARGS[@]}" diff "$stash_sha" HEAD 2>/dev/null) || true
        if [[ -n "$patch" ]]; then
          save_to_ai_trash \
            "git-reset-${reset_mode}-$(date +%Y%m%d-%H%M%S).patch" \
            "$patch" \
            "(git reset --${reset_mode}) uncommitted changes in $TOPLEVEL"
        fi
      fi

      # Also snapshot modified files directly
      "$REAL_GIT" "${GLOBAL_ARGS[@]}" diff --name-only 2>/dev/null | _snapshot_files
      "$REAL_GIT" "${GLOBAL_ARGS[@]}" diff --cached --name-only 2>/dev/null | _snapshot_files
    fi

    exec "$REAL_GIT" "$@"
    ;;

  # ── git stash ──────────────────────────────────────────────────────
  stash)
    stash_subcmd="${SUB_ARGS[0]:-}"

    case "$stash_subcmd" in
      drop)
        # Save the stash patch before dropping
        stash_ref="${SUB_ARGS[1]:-stash@{0}}"
        patch=$("$REAL_GIT" "${GLOBAL_ARGS[@]}" stash show -p "$stash_ref" 2>/dev/null) || true
        if [[ -n "$patch" ]]; then
          save_to_ai_trash \
            "git-stash-drop-$(date +%Y%m%d-%H%M%S).patch" \
            "$patch" \
            "(git stash drop $stash_ref) in $TOPLEVEL"
        fi
        ;;
      clear)
        # Save ALL stash patches before clearing
        stash_list=$("$REAL_GIT" "${GLOBAL_ARGS[@]}" stash list 2>/dev/null) || true
        if [[ -n "$stash_list" ]]; then
          all_patches=""
          while IFS= read -r entry; do
            ref="${entry%%:*}"
            header="=== $entry ==="
            patch=$("$REAL_GIT" "${GLOBAL_ARGS[@]}" stash show -p "$ref" 2>/dev/null) || true
            all_patches+="$header"$'\n'"$patch"$'\n\n'
          done <<< "$stash_list"
          if [[ -n "$all_patches" ]]; then
            save_to_ai_trash \
              "git-stash-clear-$(date +%Y%m%d-%H%M%S).patch" \
              "$all_patches" \
              "(git stash clear) all stashes in $TOPLEVEL"
          fi
        fi
        ;;
      *)
        # Non-destructive stash operations: passthrough
        exec "$REAL_GIT" "$@"
        ;;
    esac

    exec "$REAL_GIT" "$@"
    ;;

  # ── git branch ─────────────────────────────────────────────────────
  branch)
    # Only intercept -D (force delete), not -d (safe delete)
    has_force_delete=false
    branch_name=""
    for arg in "${SUB_ARGS[@]}"; do
      case "$arg" in
        -D|--delete-force) has_force_delete=true ;;
        # Also catch combined flags like -fD or -Df
        -*D*) [[ "$arg" =~ D ]] && has_force_delete=true ;;
      esac
    done

    if [[ "$has_force_delete" == true ]]; then
      # Find branch names (non-flag args after -D)
      local_after_d=false
      for arg in "${SUB_ARGS[@]}"; do
        case "$arg" in
          -D|--delete-force) local_after_d=true; continue ;;
          -*D*) local_after_d=true; continue ;;
          -*) continue ;;
        esac
        if [[ "$local_after_d" == true ]]; then
          branch_name="$arg"
          tip_sha=$("$REAL_GIT" "${GLOBAL_ARGS[@]}" rev-parse "$branch_name" 2>/dev/null) || true
          if [[ -n "$tip_sha" ]]; then
            save_to_ai_trash \
              "git-branch-D-${branch_name}-$(date +%Y%m%d-%H%M%S).txt" \
              "Branch: $branch_name
SHA: $tip_sha
Repo: $TOPLEVEL
Recovery: git branch $branch_name $tip_sha" \
              "(git branch -D $branch_name) in $TOPLEVEL"
          fi
        fi
      done
    fi

    exec "$REAL_GIT" "$@"
    ;;

  # ── git push ───────────────────────────────────────────────────────
  push)
    # Only intercept --force / -f / --force-with-lease
    has_force_push=false
    for arg in "${SUB_ARGS[@]}"; do
      case "$arg" in
        --force|-f|--force-with-lease|--force-with-lease=*) has_force_push=true ;;
        # Catch combined short flags containing f
        -*f*) [[ "$arg" =~ f ]] && has_force_push=true ;;
      esac
    done

    if [[ "$has_force_push" == true ]]; then
      # Determine remote and branch
      remote="${SUB_ARGS[0]:-origin}"
      # Skip flags to find remote name
      for arg in "${SUB_ARGS[@]}"; do
        case "$arg" in
          -*) continue ;;
          *) remote="$arg"; break ;;
        esac
      done

      # Capture current remote refs
      remote_refs=$("$REAL_GIT" "${GLOBAL_ARGS[@]}" ls-remote "$remote" 2>/dev/null) || true
      if [[ -n "$remote_refs" ]]; then
        save_to_ai_trash \
          "git-push-force-$(date +%Y%m%d-%H%M%S).txt" \
          "Remote: $remote
Repo: $TOPLEVEL
Remote refs before force push:
$remote_refs" \
          "(git push --force to $remote) in $TOPLEVEL"
      fi
    fi

    exec "$REAL_GIT" "$@"
    ;;

  # ── git filter-repo ────────────────────────────────────────────────
  filter-repo)
    echo "ai-trash: BLOCKED — git filter-repo is catastrophically destructive." >&2
    echo "ai-trash: To run it directly, use: $REAL_GIT filter-repo ${SUB_ARGS[*]}" >&2
    exit 1
    ;;

esac
