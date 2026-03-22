#!/bin/bash
# rm_wrapper.sh – transparent rm/rmdir replacement that routes files to ai-trash

PLATFORM=$(uname -s)  # Darwin or Linux
SCRIPT_NAME=$(basename "$0")

# Trash dirs differ by platform
if [[ "$PLATFORM" == "Darwin" ]]; then
  BOOT_TRASH_DIR="$HOME/.Trash/ai-trash"
  BOOT_SYSTEM_TRASH_DIR="$HOME/.Trash"
else
  BOOT_TRASH_DIR="$HOME/.local/share/Trash/ai-trash"
  BOOT_SYSTEM_TRASH_DIR="$HOME/.local/share/Trash/files"
fi

# ─── Configuration ─────────────────────────────────────────────────────
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/ai-trash/config.sh"

# Defaults — overridden by the user's config file if present.
# See config.default.sh in the repo for full documentation and comments.
MODE=selective

AI_ENV_VARS=(
  "TERM_PROGRAM=cursor"       # Cursor IDE
  "TERM_PROGRAM=vscode"       # VS Code (Copilot, Cline, Continue, Roo, etc.)
  "TERM_PROGRAM=windsurf"     # Windsurf (formerly Codeium)
  "TERM_PROGRAM=WarpTerminal" # Warp terminal (built-in Oz agent)
  "OPENCLAW_SHELL=exec"       # OpenClaw exec tool
)

AI_PROCESSES=(
  claude      # Claude Code (Anthropic)
  gemini      # Gemini CLI (Google) — standalone binary
  goose       # Goose (Block)
  opencode    # OpenCode — open-source agent
  aider       # Aider — when installed as a named script
  devin       # Devin (Cognition)
  kiro-cli    # Kiro CLI (AWS, formerly Amazon Q Developer)
  q           # Amazon Q Developer CLI (pre-Kiro rebrand, still in wide use)
  openclaw    # OpenClaw — self-hosted AI assistant gateway
  cline       # Cline — standalone CLI (VS Code extension covered by TERM_PROGRAM=vscode)
  plandex     # Plandex — large-context terminal agent
  crush       # Crush — terminal agent by Charm
  qodo        # Qodo Command — workflow automation agent
)

AI_PROCESS_ARGS=(
  "codex"       # OpenAI Codex CLI   (runs as: node .../codex/...)
  "aider"       # Aider              (runs as: python3 .../aider/...)
  "gemini-cli"  # Gemini CLI via npx (runs as: node .../@google/gemini-cli/...)
  "gh copilot"  # GitHub Copilot CLI (runs as: node .../gh-copilot/...)
  "openhands"   # OpenHands          (runs as: python3 .../openhands/...)
  "opencode"    # OpenCode           (also matched by AI_PROCESSES above)
)

# Load user config — sourced so it overrides the defaults above.
# To customise, edit: ~/.config/ai-trash/config.sh
# shellcheck source=/dev/null
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ─── Selective mode: detect AI tool in the process call chain ──────────
_is_ai_process() {
  # Tier 1: environment variable check — instant, no process lookup needed
  local var val env_check
  for env_check in "${AI_ENV_VARS[@]}"; do
    var="${env_check%%=*}"
    val="${env_check#*=}"
    [[ "${!var:-}" == "$val" ]] && return 0
  done

  # Tier 2: walk the full process tree up to PID 1 (launchd).
  # One ps snapshot for tree navigation; targeted ps calls for args matching.
  local ps_tree
  ps_tree=$(ps -A -o pid=,ppid=,comm= 2>/dev/null) || return 1

  local pid=$$
  while true; do
    local line ppid comm
    line=$(echo "$ps_tree" | awk -v p="$pid" '$1+0==p+0{print; exit}')
    [[ -z "$line" ]] && break

    ppid=$(echo "$line" | awk '{print $2+0}')
    comm=$(echo "$line" | awk '{print $3}')

    # Match executable name against AI_PROCESSES
    local proc
    for proc in "${AI_PROCESSES[@]}"; do
      [[ "$comm" == "$proc" ]] && return 0
    done

    # Match full command line against AI_PROCESS_ARGS (catches node/python-wrapped tools)
    if [[ ${#AI_PROCESS_ARGS[@]} -gt 0 ]]; then
      local args pattern
      args=$(ps -p "$pid" -o args= 2>/dev/null || true)
      for pattern in "${AI_PROCESS_ARGS[@]}"; do
        [[ "$args" == *"$pattern"* ]] && return 0
      done
    fi

    # Stop at PID 1 or if we've hit a loop
    [[ "$ppid" -le 1 || "$ppid" == "$pid" ]] && break
    pid="$ppid"
  done

  return 1
}

# ─── Platform helpers ──────────────────────────────────────────────────
_stat_dev()  { [[ "$PLATFORM" == "Darwin" ]] && stat -f %d "$1" 2>/dev/null || stat -c %d "$1" 2>/dev/null; }
_stat_size() { [[ "$PLATFORM" == "Darwin" ]] && stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null; }

# Write metadata to a trashed file.
# macOS: extended attributes. Linux: sidecar file (no xattr dependency).
_write_meta() {
  local file="$1" orig_path="$2" deleted_at="$3" deleted_by="$4" deleted_proc="$5" orig_size="$6"
  if [[ "$PLATFORM" == "Darwin" ]]; then
    xattr -w com.ai-trash.original-path     "$orig_path"   "$file" >/dev/null 2>&1
    xattr -w com.ai-trash.deleted-at        "$deleted_at"  "$file" >/dev/null 2>&1
    xattr -w com.ai-trash.deleted-by        "$deleted_by"  "$file" >/dev/null 2>&1
    xattr -w com.ai-trash.deleted-by-process "$deleted_proc" "$file" >/dev/null 2>&1
    [[ -n "$orig_size" ]] && xattr -w com.ai-trash.original-size "$orig_size" "$file" >/dev/null 2>&1
  else
    printf 'original-path=%s\ndeleted-at=%s\ndeleted-by=%s\ndeleted-by-process=%s\noriginal-size=%s\n' \
      "$orig_path" "$deleted_at" "$deleted_by" "$deleted_proc" "$orig_size" \
      > "$(dirname "$file")/.$(basename "$file").ai-trash" 2>/dev/null || true
  fi
}

# ─── Resolve trash directories ─────────────────────────────────────────
# macOS ai-trash:  boot → ~/.Trash/ai-trash          other → <mp>/.Trashes/<uid>/ai-trash
# Linux ai-trash:  boot → ~/.local/share/Trash/ai-trash  other → <mp>/.Trash-<uid>/ai-trash
# macOS system:    boot → ~/.Trash                   other → <mp>/.Trashes/<uid>
# Linux system:    boot → ~/.local/share/Trash/files  other → <mp>/.Trash-<uid>/files
get_trash_dir() {
  local file="$1"
  local file_dev home_dev mount_point
  file_dev=$(_stat_dev "$file")
  home_dev=$(_stat_dev "$HOME")
  if [[ "$file_dev" == "$home_dev" ]]; then
    printf '%s' "$BOOT_TRASH_DIR"
  else
    mount_point=$(df -P -- "$file" 2>/dev/null | awk 'NR==2 {print $NF}')
    if [[ "$PLATFORM" == "Darwin" ]]; then
      printf '%s' "${mount_point}/.Trashes/$(id -u)/ai-trash"
    else
      printf '%s' "${mount_point}/.Trash-$(id -u)/ai-trash"
    fi
  fi
}

get_system_trash_dir() {
  local file="$1"
  local file_dev home_dev mount_point
  file_dev=$(_stat_dev "$file")
  home_dev=$(_stat_dev "$HOME")
  if [[ "$file_dev" == "$home_dev" ]]; then
    printf '%s' "$BOOT_SYSTEM_TRASH_DIR"
  else
    mount_point=$(df -P -- "$file" 2>/dev/null | awk 'NR==2 {print $NF}')
    if [[ "$PLATFORM" == "Darwin" ]]; then
      printf '%s' "${mount_point}/.Trashes/$(id -u)"
    else
      printf '%s' "${mount_point}/.Trash-$(id -u)/files"
    fi
  fi
}

# ─── Resolve a unique destination path in trash_dir for a given filename ──
# Replicates Finder's collision behaviour: foo.txt → foo (2).txt → foo (3).txt
# Hidden files (.bashrc) are treated as having no extension.
get_unique_trash_path() {
  local trash_dir="$1"
  local name="$2"
  local stem ext candidate

  case "$name" in
    .*)           stem="$name"; ext="" ;;   # hidden file: no extension
    *.*)          stem="${name%.*}"; ext=".${name##*.}" ;;
    *)            stem="$name";  ext="" ;;
  esac

  candidate="$trash_dir/$name"
  local i=2
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    candidate="$trash_dir/${stem} (${i})${ext}"
    ((i++))
  done
  printf '%s' "$candidate"
}

# ─── Move files to system Trash (safe mode, non-AI calls) ──────────────
# No xattrs — these weren't deleted by an AI tool and won't appear in
# `ai-trash list`. Recoverable via Finder like any normal Trash item.
move_to_system_trash() {
  local result=0

  for f in "$@"; do
    if [[ ! -e "$f" && ! -L "$f" ]]; then
      [[ "$has_force" != true ]] && { echo "${REAL_CMD:-rm}: $f: No such file or directory" >&2; result=1; }
      continue
    fi

    local trash_dir dest
    trash_dir=$(get_system_trash_dir "$f")

    if ! mkdir -p "$trash_dir" 2>/dev/null; then
      echo "${REAL_CMD:-rm}: $f: trash unavailable on this volume, deleting permanently" >&2
      if [[ -d "$f" ]]; then /bin/rm -rf "$f"; else /bin/rm -f "$f"; fi
      [[ $? -ne 0 ]] && result=1
      continue
    fi

    dest=$(get_unique_trash_path "$trash_dir" "$(basename "$f")")
    if ! mv "$f" "$dest"; then
      echo "${REAL_CMD:-rm}: $f: could not move to trash" >&2
      result=1
    fi
  done

  return $result
}

# ─── Move files to ai-trash with metadata ──────────────────────────────
# Files land directly in trash_dir with their original name (Finder-style).
# Original path is stored as an xattr so no wrapper directory is needed.
# mtime is touched to trash-time so the 30-day cleanup uses the right clock.
move_to_ai_trash() {
  local result=0

  for f in "$@"; do
    if [[ ! -e "$f" && ! -L "$f" ]]; then
      [[ "$has_force" != true ]] && { echo "${REAL_CMD:-rm}: $f: No such file or directory" >&2; result=1; }
      continue
    fi

    local abs_path trash_dir dest
    abs_path=$(realpath "$f" 2>/dev/null || echo "$f")
    trash_dir=$(get_trash_dir "$f")

    # If the trash directory can't be created (read-only volume, permission
    # denied at share root, etc.) fall through to a real permanent delete.
    if ! mkdir -p "$trash_dir" 2>/dev/null; then
      echo "${REAL_CMD:-rm}: $f: trash unavailable on this volume, deleting permanently" >&2
      if [[ -d "$f" ]]; then
        /bin/rm -rf "$f"
      else
        /bin/rm -f "$f"
      fi
      [[ $? -ne 0 ]] && result=1
      continue
    fi

    dest=$(get_unique_trash_path "$trash_dir" "$(basename "$f")")

    # Capture size before the move (skip for dirs — too slow)
    local orig_size=""
    [[ -f "$f" || -L "$f" ]] && orig_size=$(_stat_size "$f")

    if mv "$f" "$dest"; then
      local deleted_at
      deleted_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      _write_meta "$dest" "$abs_path" "$deleted_at" "$(id -un)" \
        "$(ps -p $PPID -o comm= 2>/dev/null | sed 's|.*/||')" "$orig_size"
      touch "$dest" 2>/dev/null  # update mtime so find -mtime +30 uses trash-time
    else
      echo "${REAL_CMD:-rm}: $f: could not move to trash" >&2
      result=1
    fi
  done

  return $result
}

# Determine the real command based on how we were called
case "$SCRIPT_NAME" in
  rmdir|rmdir_wrapper.sh|rmdir_wrapper)
    REAL_CMD="rmdir"
    ;;
  *)
    REAL_CMD="rm"
    ;;
esac

# Guard: fall through to real rm/rmdir in non-user contexts
# (system launchd daemons where $HOME is unset or is root's home)
if [[ -z "$HOME" || "$HOME" == "/var/root" ]]; then
  exec /bin/"$REAL_CMD" "$@"
fi

# selective (default) — non-AI calls pass straight through to /bin/rm unchanged
# safe                — non-AI calls route to the system Trash instead of /bin/rm
SAFE_PASSTHROUGH=false
if [[ "$MODE" == "safe" ]]; then
  if ! _is_ai_process; then
    SAFE_PASSTHROUGH=true
  fi
else
  if ! _is_ai_process; then
    exec /bin/"$REAL_CMD" "$@"
  fi
fi

# Pass through unsupported rm options to /bin/rm (e.g. --help, -P)
for arg in "$@"; do
  if [[ "$arg" == "--help" || "$arg" == "-h" || "$arg" == "-P" || "$arg" == "--version" ]]; then
    exec /bin/"$REAL_CMD" "$@"
  fi
done

# If filename is exactly "/", ".", or ".." – behave like real rm
for path in "$@"; do
  if [[ "$path" == "/" || "$path" == "." || "$path" == ".." ]]; then
    echo "$REAL_CMD: illegal file name – refusing to remove \"$path\"" >&2
    exit 1
  fi
done

# Check for invalid options by testing with the real command first
# This ensures we get proper error messages for invalid flags
# Important: respect -- (arguments after it are operands, not options)
if [[ "$REAL_CMD" == "rm" ]]; then
  # Valid rm options: -d, -f, -i, -I, -P, -R, -r, -v, -W, -x
  after_dd=false
  for arg in "$@"; do
    if [[ "$after_dd" == false && "$arg" == "--" ]]; then
      after_dd=true
      continue
    fi
    if [[ "$after_dd" == false && "$arg" =~ ^- ]]; then
      if [[ ! "$arg" =~ ^-[dfiIPRrvWx]+$ ]]; then
        # Invalid option detected, let real rm handle the error
        exec /bin/rm "$@"
      fi
    fi
  done
elif [[ "$REAL_CMD" == "rmdir" ]]; then
  # Valid rmdir options: -p, -v
  after_dd=false
  for arg in "$@"; do
    if [[ "$after_dd" == false && "$arg" == "--" ]]; then
      after_dd=true
      continue
    fi
    if [[ "$after_dd" == false && "$arg" =~ ^- ]]; then
      if [[ ! "$arg" =~ ^-[pv]+$ ]]; then
        # Invalid option detected, let real rmdir handle the error
        exec /bin/rmdir "$@"
      fi
    fi
  done
fi

# ─── Helper: check if directory is empty ───────────────────────────────
is_empty_dir() {
  local dir="$1"
  [[ -d "$dir" ]] && [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]
}

# ─── Handle rmdir mode ─────────────────────────────────────────────────
if [[ "$REAL_CMD" == "rmdir" ]]; then
  # Parse arguments with -- support for rmdir
  operands=()
  rmdir_p=false
  rmdir_v=false
  after_double_dash=false

  for arg in "$@"; do
    if [[ "$after_double_dash" == false && "$arg" == "--" ]]; then
      after_double_dash=true
      continue
    fi
    if [[ "$after_double_dash" == false && "$arg" =~ ^- ]]; then
      [[ "$arg" =~ p ]] && rmdir_p=true
      [[ "$arg" =~ v ]] && rmdir_v=true
      continue
    else
      operands+=("$arg")
    fi
  done

  exit_code=0

  # Helper: remove single empty directory
  remove_empty_dir() {
    local dir="$1"

    if [[ ! -d "$dir" ]]; then
      echo "rmdir: $dir: No such file or directory" >&2
      return 1
    fi

    if ! is_empty_dir "$dir"; then
      echo "rmdir: $dir: Directory not empty" >&2
      return 1
    fi

    if [[ "$rmdir_v" == true ]]; then
      echo "rmdir: removing directory, '$dir'"
    fi

    if [[ "$SAFE_PASSTHROUGH" == true ]]; then
      move_to_system_trash "$dir"
    else
      move_to_ai_trash "$dir"
    fi
    return $?
  }

  # Process each operand
  for dir in "${operands[@]}"; do
    if ! remove_empty_dir "$dir"; then
      exit_code=1
      continue
    fi

    # Handle -p: remove parent directories
    if [[ "$rmdir_p" == true ]]; then
      parent="$dir"
      while true; do
        # Get parent directory
        parent=$(dirname "$parent")

        # Stop at root or current dir
        [[ "$parent" == "/" || "$parent" == "." || -z "$parent" ]] && break

        # Try to remove parent (will fail if not empty, which is fine)
        if is_empty_dir "$parent"; then
          if ! remove_empty_dir "$parent"; then
            # Parent not removable, stop climbing
            break
          fi
        else
          # Parent not empty, stop climbing
          break
        fi
      done
    fi
  done

  exit $exit_code
fi

# ─── rm mode: Parse arguments with -- support ──────────────────────────
flags=()
operands=()
after_double_dash=false

for arg in "$@"; do
  if [[ "$after_double_dash" == false && "$arg" == "--" ]]; then
    after_double_dash=true
    flags+=("--")
    continue
  fi
  if [[ "$after_double_dash" == false && "$arg" =~ ^- ]]; then
    flags+=("$arg")
  else
    operands+=("$arg")
  fi
done

# ─── Extract flag meanings ─────────────────────────────────────────────
has_recursive=false
has_dir_flag=false
has_interactive=false
has_interactive_once=false
has_force=false
has_verbose=false

for flag in "${flags[@]}"; do
  [[ "$flag" == "--" ]] && continue
  [[ "$flag" =~ [rR] ]] && has_recursive=true
  [[ "$flag" =~ d ]] && has_dir_flag=true
  [[ "$flag" =~ i ]] && has_interactive=true
  [[ "$flag" =~ I ]] && has_interactive_once=true
  [[ "$flag" =~ f ]] && has_force=true
  [[ "$flag" =~ v ]] && has_verbose=true
done

# -f overrides -i/-I
if [[ "$has_force" == true ]]; then
  has_interactive=false
  has_interactive_once=false
fi

# No TTY: suppress interactive prompts to avoid hanging in pipes or launchd user agents
if [[ ! -t 0 ]]; then
  has_interactive=false
  has_interactive_once=false
fi

# Build rm_flags: flags for /bin/rm with -i/-I stripped (we handle prompting)
rm_flags=()
for flag in "${flags[@]}"; do
  if [[ "$flag" == "--" ]]; then
    rm_flags+=("$flag")
  else
    # Strip i and I from the flag
    stripped="${flag//i/}"
    stripped="${stripped//I/}"
    # Only add if there's something left besides the dash
    if [[ "$stripped" != "-" && -n "$stripped" ]]; then
      rm_flags+=("$stripped")
    fi
  fi
done

# ─── Check directories without -r/-R/-d (don't exit early) ─────────────
exit_code=0
had_dir_error=false

if [[ "$has_recursive" == false && "$has_dir_flag" == false ]]; then
  for path in "${operands[@]}"; do
    if [[ -d "$path" ]]; then
      echo "rm: $path: is a directory" >&2
      had_dir_error=true
    fi
  done
fi

# ─── Classify operands ─────────────────────────────────────────────────
files=()
empty_dirs=()  # for -d flag

for path in "${operands[@]}"; do
  if [[ -d "$path" ]]; then
    if [[ "$has_recursive" == true ]]; then
      files+=("$path")  # mv handles directories recursively
    elif [[ "$has_dir_flag" == true ]]; then
      if is_empty_dir "$path"; then
        empty_dirs+=("$path")
      else
        echo "rm: $path: Directory not empty" >&2
        had_dir_error=true
      fi
    fi
    # else: already errored above, skip
  else
    # Regular files (existing or not - move_to_ai_trash handles missing)
    files+=("$path")
  fi
done

trash_files=("${files[@]}")
trash_dirs=("${empty_dirs[@]}")

# ─── Interactive prompts (-I: prompt once if >3 items or recursive) ────
total_count=$((${#trash_files[@]} + ${#trash_dirs[@]}))

if [[ "$has_interactive_once" == true ]]; then
  should_prompt=false
  if [[ $total_count -gt 3 ]]; then
    should_prompt=true
  fi
  # Also prompt for recursive directory deletion
  if [[ "$has_recursive" == true ]]; then
    for f in "${trash_files[@]}"; do
      if [[ -d "$f" ]]; then
        should_prompt=true
        break
      fi
    done
  fi

  if [[ "$should_prompt" == true ]]; then
    read -p "rm: remove $total_count arguments? " response
    if [[ ! "$response" =~ ^[Yy] ]]; then
      exit 0
    fi
  fi
fi

# ─── Process deletions ─────────────────────────────────────────────────

# Helper for interactive single-file prompts
prompt_and_process() {
  local file="$1"

  if [[ "$has_interactive" == true ]]; then
    read -p "rm: remove '$file'? " response
    if [[ ! "$response" =~ ^[Yy] ]]; then
      return 0  # Skip this file
    fi
  fi

  if [[ "$has_verbose" == true ]]; then
    echo "$file"
  fi
  if [[ "$SAFE_PASSTHROUGH" == true ]]; then
    move_to_system_trash "$file"
  else
    move_to_ai_trash "$file"
  fi

  return $?
}

# Trash files
if [[ ${#trash_files[@]} -gt 0 ]]; then
  if [[ "$has_interactive" == true ]]; then
    for f in "${trash_files[@]}"; do
      prompt_and_process "$f"
      [[ $? -ne 0 ]] && exit_code=1
    done
  else
    if [[ "$has_verbose" == true ]]; then
      printf '%s\n' "${trash_files[@]}"
    fi
    if [[ "$SAFE_PASSTHROUGH" == true ]]; then
      move_to_system_trash "${trash_files[@]}"
    else
      move_to_ai_trash "${trash_files[@]}"
    fi
    [[ $? -ne 0 ]] && exit_code=1
  fi
fi

# Trash empty directories (for -d flag)
if [[ ${#trash_dirs[@]} -gt 0 ]]; then
  if [[ "$has_interactive" == true ]]; then
    for d in "${trash_dirs[@]}"; do
      prompt_and_process "$d"
      [[ $? -ne 0 ]] && exit_code=1
    done
  else
    if [[ "$has_verbose" == true ]]; then
      printf '%s\n' "${trash_dirs[@]}"
    fi
    if [[ "$SAFE_PASSTHROUGH" == true ]]; then
      move_to_system_trash "${trash_dirs[@]}"
    else
      move_to_ai_trash "${trash_dirs[@]}"
    fi
    [[ $? -ne 0 ]] && exit_code=1
  fi
fi

# Set error if we had directory errors earlier
[[ "$had_dir_error" == true ]] && exit_code=1

exit $exit_code
