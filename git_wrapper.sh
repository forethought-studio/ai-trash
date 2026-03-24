#!/bin/bash
# git_wrapper.sh – transparent git replacement that snapshots files before destructive operations
#
# "Snapshot Before Execute": for AI callers running destructive git subcommands,
# copy affected files to ai-trash before letting git run normally.
# Non-AI callers and non-destructive subcommands pass through instantly.

# Source shared library (same directory as this script, resolve symlinks)
_WRAPPER_PATH="${BASH_SOURCE[0]}"
while [[ -L "$_WRAPPER_PATH" ]]; do _WRAPPER_PATH=$(readlink "$_WRAPPER_PATH"); done
# shellcheck source=ai-trash-lib.sh
source "$(cd "$(dirname "$_WRAPPER_PATH")" && pwd)/ai-trash-lib.sh"

REAL_CMD="git"

# ─── Find the real git binary (skip ourselves in PATH) ─────────────────
_find_real_git() {
  local wrapper_dir _wp="${BASH_SOURCE[0]}"
  while [[ -L "$_wp" ]]; do _wp=$(readlink "$_wp"); done
  wrapper_dir=$(cd "$(dirname "$_wp")" && pwd)

  local IFS=:
  for dir in $PATH; do
    local resolved
    resolved=$(cd "$dir" 2>/dev/null && pwd) || continue
    [[ "$resolved" == "$wrapper_dir" ]] && continue
    if [[ -x "$dir/git" ]]; then
      # Skip if this is a symlink that resolves to our wrapper
      local candidate="$dir/git"
      while [[ -L "$candidate" ]]; do candidate=$(readlink "$candidate"); done
      [[ "$(basename "$candidate")" == "git_wrapper.sh" ]] && continue
      printf '%s' "$dir/git"
      return
    fi
  done

  # Fallback to common locations
  for g in /usr/bin/git /usr/local/bin/git /opt/homebrew/bin/git; do
    [[ -x "$g" ]] && { printf '%s' "$g"; return; }
  done

  echo "ai-trash git wrapper: cannot find real git binary" >&2
  exit 127
}

REAL_GIT=$(_find_real_git)

# ─── Guards ────────────────────────────────────────────────────────────
# Non-user contexts: instant passthrough
if [[ -z "$HOME" || "$HOME" == "/var/root" ]]; then
  exec "$REAL_GIT" "$@"
fi

# Feature toggle
if [[ "${GIT_PROTECTION:-true}" != true ]]; then
  exec "$REAL_GIT" "$@"
fi

# Non-AI callers: instant passthrough
if ! _is_ai_process; then
  exec "$REAL_GIT" "$@"
fi

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

SUBCMD=$(_get_git_subcommand "$@")

# Non-destructive subcommands: instant passthrough
case "$SUBCMD" in
  clean|checkout|restore|reset|stash|branch|push|filter-repo) ;; # handled below
  *) exec "$REAL_GIT" "$@" ;;
esac

# ─── Read subcommand args into array ──────────────────────────────────
SUB_ARGS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && SUB_ARGS+=("$line")
done < <(_get_subcommand_args "$@")

# ─── Get repo toplevel for resolving relative paths ────────────────────
TOPLEVEL=$("$REAL_GIT" rev-parse --show-toplevel 2>/dev/null) || {
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
      dry_output=$(LC_ALL=C "$REAL_GIT" clean -n "${SUB_ARGS[@]}" 2>/dev/null) || true
      if [[ -n "$dry_output" ]]; then
        echo "$dry_output" | sed -n 's/^Would remove //p' | while IFS= read -r f; do
          [[ -z "$f" ]] && continue
          # git clean -n outputs paths relative to cwd
          [[ -e "$f" || -L "$f" ]] && snapshot_to_ai_trash "$f"
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
      "$REAL_GIT" diff --name-only 2>/dev/null | _snapshot_files
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
    "$REAL_GIT" diff --name-only 2>/dev/null | _snapshot_files
    # Also snapshot staged changes (visible via --cached)
    "$REAL_GIT" diff --cached --name-only 2>/dev/null | _snapshot_files

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
      stash_sha=$("$REAL_GIT" stash create 2>/dev/null) || true
      if [[ -n "$stash_sha" ]]; then
        patch=$("$REAL_GIT" diff "$stash_sha" HEAD 2>/dev/null) || true
        if [[ -n "$patch" ]]; then
          save_to_ai_trash \
            "git-reset-${reset_mode}-$(date +%Y%m%d-%H%M%S).patch" \
            "$patch" \
            "(git reset --${reset_mode}) uncommitted changes in $TOPLEVEL"
        fi
      fi

      # Also snapshot modified files directly
      "$REAL_GIT" diff --name-only 2>/dev/null | _snapshot_files
      "$REAL_GIT" diff --cached --name-only 2>/dev/null | _snapshot_files
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
        patch=$("$REAL_GIT" stash show -p "$stash_ref" 2>/dev/null) || true
        if [[ -n "$patch" ]]; then
          save_to_ai_trash \
            "git-stash-drop-$(date +%Y%m%d-%H%M%S).patch" \
            "$patch" \
            "(git stash drop $stash_ref) in $TOPLEVEL"
        fi
        ;;
      clear)
        # Save ALL stash patches before clearing
        stash_list=$("$REAL_GIT" stash list 2>/dev/null) || true
        if [[ -n "$stash_list" ]]; then
          all_patches=""
          while IFS= read -r entry; do
            ref="${entry%%:*}"
            header="=== $entry ==="
            patch=$("$REAL_GIT" stash show -p "$ref" 2>/dev/null) || true
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
          tip_sha=$("$REAL_GIT" rev-parse "$branch_name" 2>/dev/null) || true
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
      remote_refs=$("$REAL_GIT" ls-remote "$remote" 2>/dev/null) || true
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

# Fallback: passthrough (should not reach here due to case above)
exec "$REAL_GIT" "$@"
