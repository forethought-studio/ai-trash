#!/bin/bash
# rm_wrapper.sh – transparent rm/rmdir/unlink replacement that routes files to ai-trash

# Source shared library (same directory as this script, resolve symlinks)
_WRAPPER_PATH="${BASH_SOURCE[0]}"
while [[ -L "$_WRAPPER_PATH" ]]; do _WRAPPER_PATH=$(readlink "$_WRAPPER_PATH"); done
# shellcheck source=ai-trash-lib.sh
source "$(cd "$(dirname "$_WRAPPER_PATH")" && pwd)/ai-trash-lib.sh"

SCRIPT_NAME=$(basename "$0")

# Determine the real command based on how we were called
case "$SCRIPT_NAME" in
  rmdir|rmdir_wrapper.sh|rmdir_wrapper)
    REAL_CMD="rmdir"
    ;;
  unlink)
    REAL_CMD="unlink"
    ;;
  *)
    REAL_CMD="rm"
    ;;
esac

# Guard: fall through to real rm/rmdir/unlink in non-user contexts
# (system launchd daemons where $HOME is unset or is root's home)
if [[ -z "$HOME" || "$HOME" == "/var/root" ]]; then
  if [[ "$REAL_CMD" == "unlink" ]]; then
    exec /usr/bin/unlink "$@"
  else
    exec /bin/"$REAL_CMD" "$@"
  fi
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
    if [[ "$REAL_CMD" == "unlink" ]]; then
      exec /usr/bin/unlink "$@"
    else
      exec /bin/"$REAL_CMD" "$@"
    fi
  fi
fi

# ─── Handle unlink mode ──────────────────────────────────────────────────
# unlink takes exactly one argument, no flags.
if [[ "$REAL_CMD" == "unlink" ]]; then
  if [[ $# -ne 1 ]]; then
    exec /usr/bin/unlink "$@"  # let real unlink handle the error
  fi

  local_file="$1"

  if [[ ! -e "$local_file" && ! -L "$local_file" ]]; then
    echo "unlink: $local_file: No such file or directory" >&2
    exit 1
  fi

  if [[ -d "$local_file" ]]; then
    echo "unlink: $local_file: Is a directory" >&2
    exit 1
  fi

  if [[ "$SAFE_PASSTHROUGH" == true ]]; then
    move_to_system_trash "$local_file"
  else
    move_to_ai_trash "$local_file"
  fi
  exit $?
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
