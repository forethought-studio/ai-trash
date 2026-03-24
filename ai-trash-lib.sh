# ai-trash-lib.sh — shared library for ai-trash wrappers
# Sourced by rm_wrapper.sh, git_wrapper.sh, and find_wrapper.sh.
# Do not execute directly.

# Guard against double-sourcing
[[ -n "${_AI_TRASH_LIB_LOADED:-}" ]] && return 0
_AI_TRASH_LIB_LOADED=1

PLATFORM=$(uname -s)  # Darwin or Linux

# Trash dirs differ by platform
if [[ "$PLATFORM" == "Darwin" ]]; then
  BOOT_TRASH_DIR="$HOME/.Trash"
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
  "CLAUDECODE=1"              # Claude Code shell session (set in every spawned shell)
  "CODEX_SANDBOX=seatbelt"    # OpenAI Codex CLI (set in every sandboxed subprocess on macOS)
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

# New wrapper toggles — default to true, respect env overrides
GIT_PROTECTION=${GIT_PROTECTION:-true}
FIND_PROTECTION=${FIND_PROTECTION:-true}

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

# ─── Identify the AI process that triggered this deletion ─────────────
# Walks the process tree (like _is_ai_process) and prints the full command
# line of the first matched AI ancestor. Falls back to the immediate parent.
_detect_ai_process_command() {
  # Check env-var tier first — if matched, the parent is the calling shell,
  # so walk up to grandparent for a more useful label.
  local var val env_check
  for env_check in "${AI_ENV_VARS[@]}"; do
    var="${env_check%%=*}"
    val="${env_check#*=}"
    if [[ "${!var:-}" == "$val" ]]; then
      # Return a useful label: the value if descriptive (e.g. "cursor"),
      # or the variable name if the value is just a boolean flag (e.g. "CLAUDECODE")
      if [[ "$val" =~ ^(1|true|yes)$ ]]; then
        printf '%s' "$var"
      else
        printf '%s' "$val"
      fi
      return
    fi
  done

  # Walk the process tree looking for the AI ancestor.
  local ps_tree
  ps_tree=$(ps -A -o pid=,ppid=,comm= 2>/dev/null) || { ps -p $PPID -o comm= 2>/dev/null; return; }

  local pid=$$
  while true; do
    local line ppid comm
    line=$(echo "$ps_tree" | awk -v p="$pid" '$1+0==p+0{print; exit}')
    [[ -z "$line" ]] && break

    ppid=$(echo "$line" | awk '{print $2+0}')
    comm=$(echo "$line" | awk '{print $3}')

    for proc in "${AI_PROCESSES[@]}"; do
      if [[ "$comm" == "$proc" ]]; then
        # Found the AI process — print its full command line
        ps -p "$pid" -o command= 2>/dev/null | sed 's/^ *//'
        return
      fi
    done

    if [[ ${#AI_PROCESS_ARGS[@]} -gt 0 ]]; then
      local args pattern
      args=$(ps -p "$pid" -o args= 2>/dev/null || true)
      for pattern in "${AI_PROCESS_ARGS[@]}"; do
        if [[ "$args" == *"$pattern"* ]]; then
          printf '%s' "$args" | sed 's/^ *//'
          return
        fi
      done
    fi

    [[ "$ppid" -le 1 || "$ppid" == "$pid" ]] && break
    pid="$ppid"
  done

  # No AI process found — report the parent's full command line for forensics.
  local parent_cmd
  parent_cmd=$(ps -p $PPID -o command= 2>/dev/null | sed 's/^ *//; s/^-//')
  if [[ -n "$parent_cmd" ]]; then
    printf '%s (unknown)' "$parent_cmd"
  else
    printf 'unknown'
  fi
}

# ─── Build the full process ancestor chain for forensics ─────────────
# Returns full command lines: "bash /Users/user/bin/q list > zsh > claude > ..."
_build_process_chain() {
  local ps_tree chain="" pid=$$
  ps_tree=$(ps -A -o pid=,ppid=,comm= 2>/dev/null) || return

  while true; do
    local line ppid comm
    line=$(echo "$ps_tree" | awk -v p="$pid" '$1+0==p+0{print; exit}')
    [[ -z "$line" ]] && break

    ppid=$(echo "$line" | awk '{print $2+0}')
    # Get the process label: for interpreters (bash, python3, node, etc.) include
    # the script argument so "bash" becomes "bash /Users/user/bin/q list".
    # For everything else, just the basename is enough.
    local base_comm full_args
    base_comm=$(echo "$line" | awk '{print $3}' | sed 's|.*/||; s/^-//')
    case "$base_comm" in
      bash|sh|zsh|dash|fish|python|python3|node|ruby|perl)
        full_args=$(ps -p "$pid" -o args= 2>/dev/null | sed 's/^ *//; s/^-//' || true)
        # Use full args only if short enough and adds info beyond the interpreter name
        if [[ -n "$full_args" && ${#full_args} -le 120 && "$full_args" != "$base_comm" ]]; then
          comm="$full_args"
        else
          comm="$base_comm"
        fi
        ;;
      *)
        comm="$base_comm"
        ;;
    esac

    [[ -n "$chain" ]] && chain="$chain > "
    chain="$chain$comm"

    [[ "$ppid" -le 1 || "$ppid" == "$pid" ]] && break
    pid="$ppid"
  done

  printf '%s' "$chain"
}

# ─── Platform helpers ──────────────────────────────────────────────────
_stat_dev()  { [[ "$PLATFORM" == "Darwin" ]] && stat -f %d "$1" 2>/dev/null || stat -c %d "$1" 2>/dev/null; }
_stat_size() { [[ "$PLATFORM" == "Darwin" ]] && stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null; }

# Write metadata to a trashed file.
# macOS: extended attributes. Linux: sidecar file (no xattr dependency).
_write_meta() {
  local file="$1" orig_path="$2" deleted_at="$3" deleted_by="$4" deleted_proc="$5" orig_size="$6" proc_chain="$7"
  if [[ "$PLATFORM" == "Darwin" ]]; then
    xattr -w com.ai-trash.original-path     "$orig_path"   "$file" >/dev/null 2>&1
    xattr -w com.ai-trash.deleted-at        "$deleted_at"  "$file" >/dev/null 2>&1
    xattr -w com.ai-trash.deleted-by        "$deleted_by"  "$file" >/dev/null 2>&1
    xattr -w com.ai-trash.deleted-by-process "$deleted_proc" "$file" >/dev/null 2>&1
    [[ -n "$orig_size" ]] && xattr -w com.ai-trash.original-size "$orig_size" "$file" >/dev/null 2>&1
    [[ -n "$proc_chain" ]] && xattr -w com.ai-trash.process-chain "$proc_chain" "$file" >/dev/null 2>&1
  else
    printf 'original-path=%s\ndeleted-at=%s\ndeleted-by=%s\ndeleted-by-process=%s\noriginal-size=%s\nprocess-chain=%s\n' \
      "$orig_path" "$deleted_at" "$deleted_by" "$deleted_proc" "$orig_size" "$proc_chain" \
      > "$(dirname "$file")/.$(basename "$file").ai-trash" 2>/dev/null || true
  fi
}

# ─── Resolve trash directories ─────────────────────────────────────────
# macOS ai-trash:  boot -> ~/.Trash (xattr-tagged)    other -> <mp>/.Trashes/<uid>/ai-trash
# Linux ai-trash:  boot -> ~/.local/share/Trash/ai-trash  other -> <mp>/.Trash-<uid>/ai-trash
# macOS system:    boot -> ~/.Trash                   other -> <mp>/.Trashes/<uid>
# Linux system:    boot -> ~/.local/share/Trash/files  other -> <mp>/.Trash-<uid>/files
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
# Replicates Finder's collision behaviour: foo.txt -> foo (2).txt -> foo (3).txt
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

# ─── Move a single file via FSMoveObjectToTrashSync (macOS boot volume) ─
# Writes ptbL/ptbN Put Back metadata to DS_Store. No ai-trash xattrs.
# Outputs the resulting trash path on success, empty string on failure.
_fsmove_single() {
  local abs="$1"
  local home_dir="$HOME"
  python3 - "$abs" "$home_dir" 2>/dev/null <<'PYEOF'
import sys, os, ctypes, pwd

abs_path, home = sys.argv[1], sys.argv[2]
# Skip when HOME is overridden (test environments)
if home != pwd.getpwuid(os.getuid()).pw_dir:
    print(''); sys.exit(0)

trash_prefix = home + '/.Trash/'
CS = ctypes.cdll.LoadLibrary(
    '/System/Library/Frameworks/CoreServices.framework/CoreServices')

class FSRef(ctypes.Structure):
    _fields_ = [('hidden', ctypes.c_uint8 * 80)]

CS.FSPathMakeRef.restype = ctypes.c_int32
CS.FSPathMakeRef.argtypes = [ctypes.c_char_p, ctypes.POINTER(FSRef),
                              ctypes.POINTER(ctypes.c_bool)]
CS.FSRefMakePath.restype = ctypes.c_int32
CS.FSRefMakePath.argtypes = [ctypes.POINTER(FSRef), ctypes.c_char_p, ctypes.c_uint32]
CS.FSMoveObjectToTrashSync.restype = ctypes.c_int32
CS.FSMoveObjectToTrashSync.argtypes = [ctypes.POINTER(FSRef), ctypes.POINTER(FSRef),
                                        ctypes.c_uint32]
try:
    ref = FSRef(); is_dir = ctypes.c_bool(False)
    if CS.FSPathMakeRef(abs_path.encode(), ctypes.byref(ref),
                        ctypes.byref(is_dir)) != 0:
        print(''); sys.exit(0)
    result_ref = FSRef()
    if CS.FSMoveObjectToTrashSync(ctypes.byref(ref),
                                  ctypes.byref(result_ref), 0) != 0:
        print(''); sys.exit(0)
    buf = ctypes.create_string_buffer(4096)
    CS.FSRefMakePath(ctypes.byref(result_ref), buf, 4096)
    rp = buf.value.decode()
    print(rp if rp.startswith(trash_prefix) else '')
except Exception:
    print('')
PYEOF
}

# ─── Move files to system Trash (safe mode, non-AI calls) ──────────────
# Writes ai-trash xattrs/sidecar metadata so the original path, deletion
# time, and deleting process are always recoverable. Uses
# FSMoveObjectToTrashSync on macOS boot volume for Finder Put Back support.
move_to_system_trash() {
  local result=0
  local home_dev=""
  [[ "$PLATFORM" == "Darwin" ]] && home_dev=$(_stat_dev "$HOME")

  local deleted_at deleted_by deleted_proc proc_chain
  deleted_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  deleted_by=$(id -un)
  deleted_proc=$(_detect_ai_process_command)
  proc_chain=$(_build_process_chain)

  for f in "$@"; do
    if [[ ! -e "$f" && ! -L "$f" ]]; then
      [[ "${has_force:-false}" != true ]] && { echo "${REAL_CMD:-rm}: $f: No such file or directory" >&2; result=1; }
      continue
    fi

    local abs="" sz=""
    abs=$(realpath "$f" 2>/dev/null || echo "$f")
    [[ -f "$f" || -L "$f" ]] && sz=$(_stat_size "$f")

    # macOS boot-volume: use FSMoveObjectToTrashSync for Put Back support
    if [[ "$PLATFORM" == "Darwin" && "$(_stat_dev "$f")" == "$home_dev" ]]; then
      local rp
      rp=$(_fsmove_single "$abs")
      if [[ -n "$rp" ]]; then
        _write_meta "$rp" "$abs" "$deleted_at" "$deleted_by" "$deleted_proc" "$sz" "$proc_chain"
        touch "$rp" 2>/dev/null
        continue
      fi
      # fall through to mv on failure
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
    if mv "$f" "$dest"; then
      _write_meta "$dest" "$abs" "$deleted_at" "$deleted_by" "$deleted_proc" "$sz" "$proc_chain"
      touch "$dest" 2>/dev/null
    else
      echo "${REAL_CMD:-rm}: $f: could not move to trash" >&2
      result=1
    fi
  done

  return $result
}

# ─── Move a single file to ai-trash subdirectory via mv ────────────────
# Fallback for when NSFileManager is unavailable or for non-boot volumes.
# Assumes the file exists (caller's responsibility).
_mv_file_to_ai_trash_dir() {
  local f="$1" abs_path="$2" deleted_at="$3" deleted_by="$4" deleted_proc="$5" orig_size="$6" proc_chain="$7"
  local trash_dir dest
  trash_dir=$(get_trash_dir "$f")
  if ! mkdir -p "$trash_dir" 2>/dev/null; then
    echo "${REAL_CMD:-rm}: $f: trash unavailable on this volume, deleting permanently" >&2
    if [[ -d "$f" ]]; then /bin/rm -rf "$f"; else /bin/rm -f "$f"; fi
    return $?
  fi
  dest=$(get_unique_trash_path "$trash_dir" "$(basename "$f")")
  if mv "$f" "$dest"; then
    _write_meta "$dest" "$abs_path" "$deleted_at" "$deleted_by" "$deleted_proc" "$orig_size" "$proc_chain"
    touch "$dest" 2>/dev/null
  else
    echo "${REAL_CMD:-rm}: $f: could not move to trash" >&2
    return 1
  fi
}

# ─── Move files to ai-trash with metadata ──────────────────────────────
# macOS boot volume: uses FSMoveObjectToTrashSync (CoreServices) which moves the file
# to ~/.Trash/ and writes DS_Store ptbL/ptbN Put Back metadata — no automation
# permissions required. Falls back to mv on failure.
# Other volumes and Linux: mv to ai-trash subdirectory (unchanged).
move_to_ai_trash() {
  local result=0
  local deleted_at deleted_by deleted_proc proc_chain
  deleted_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  deleted_by=$(id -un)
  deleted_proc=$(_detect_ai_process_command)
  proc_chain=$(_build_process_chain)

  # ── macOS: route boot-volume files through FSMoveObjectToTrashSync for Put Back ──
  if [[ "$PLATFORM" == "Darwin" ]]; then
    local home_dev
    home_dev=$(_stat_dev "$HOME")
    local -a boot_srcs=() boot_abs=() boot_sizes=() other_files=()

    for f in "$@"; do
      if [[ ! -e "$f" && ! -L "$f" ]]; then
        [[ "${has_force:-false}" != true ]] && { echo "${REAL_CMD:-rm}: $f: No such file or directory" >&2; result=1; }
        continue
      fi
      local abs="" sz=""
      abs=$(realpath "$f" 2>/dev/null || echo "$f")
      if [[ "$(_stat_dev "$f")" == "$home_dev" ]]; then
        [[ -f "$f" || -L "$f" ]] && sz=$(_stat_size "$f")
        boot_srcs+=("$f"); boot_abs+=("$abs"); boot_sizes+=("$sz")
      else
        other_files+=("$f")
      fi
    done

    # Batch-trash boot-volume files via FSMoveObjectToTrashSync — writes Put Back metadata
    if [[ ${#boot_srcs[@]} -gt 0 ]]; then
      local paths_tmp="" py_out=""
      paths_tmp=$(mktemp 2>/dev/null) || true
      if [[ -n "$paths_tmp" ]]; then
        printf '%s\0' "${boot_abs[@]}" > "$paths_tmp"
        py_out=$(python3 - "$paths_tmp" 2>/dev/null <<'PYEOF'
import sys, os, ctypes, pwd

with open(sys.argv[1], 'rb') as fh:
    paths = [p.decode() for p in fh.read().split(b'\0') if p]

home = os.environ.get('HOME', '')
# Skip when HOME is overridden (e.g. test environments)
if home != pwd.getpwuid(os.getuid()).pw_dir:
    for _ in paths:
        print('')
    sys.exit(0)

trash_prefix = home + '/.Trash/'

CS = ctypes.cdll.LoadLibrary(
    '/System/Library/Frameworks/CoreServices.framework/CoreServices')

class FSRef(ctypes.Structure):
    _fields_ = [('hidden', ctypes.c_uint8 * 80)]

CS.FSPathMakeRef.restype = ctypes.c_int32
CS.FSPathMakeRef.argtypes = [ctypes.c_char_p, ctypes.POINTER(FSRef),
                              ctypes.POINTER(ctypes.c_bool)]
CS.FSRefMakePath.restype = ctypes.c_int32
CS.FSRefMakePath.argtypes = [ctypes.POINTER(FSRef), ctypes.c_char_p, ctypes.c_uint32]
CS.FSMoveObjectToTrashSync.restype = ctypes.c_int32
CS.FSMoveObjectToTrashSync.argtypes = [ctypes.POINTER(FSRef), ctypes.POINTER(FSRef),
                                        ctypes.c_uint32]

for path in paths:
    try:
        ref = FSRef(); is_dir = ctypes.c_bool(False)
        if CS.FSPathMakeRef(path.encode(), ctypes.byref(ref),
                            ctypes.byref(is_dir)) != 0:
            print(''); continue
        result_ref = FSRef()
        if CS.FSMoveObjectToTrashSync(ctypes.byref(ref),
                                      ctypes.byref(result_ref), 0) != 0:
            print(''); continue
        buf = ctypes.create_string_buffer(4096)
        CS.FSRefMakePath(ctypes.byref(result_ref), buf, 4096)
        rp = buf.value.decode()
        print(rp if rp.startswith(trash_prefix) else '')
    except Exception:
        print('')
PYEOF
        ) || py_out=""
        /bin/rm -f "$paths_tmp"
      fi

      # Map result paths back to source files (one line per entry, empty = failure)
      local -a result_paths=()
      while IFS= read -r line; do
        result_paths+=("$line")
      done <<< "$py_out"

      for i in "${!boot_srcs[@]}"; do
        local f="${boot_srcs[$i]}" abs="${boot_abs[$i]}" sz="${boot_sizes[$i]}"
        local rp="${result_paths[$i]:-}"
        if [[ -n "$rp" && (-e "$rp" || -L "$rp") ]]; then
          # FSMoveObjectToTrashSync succeeded: file is in ~/.Trash/, stamp with our xattrs
          _write_meta "$rp" "$abs" "$deleted_at" "$deleted_by" "$deleted_proc" "$sz" "$proc_chain"
          touch "$rp" 2>/dev/null
        else
          # FSMoveObjectToTrashSync failed: fall back to mv into ai-trash subdir
          _mv_file_to_ai_trash_dir "$f" "$abs" "$deleted_at" "$deleted_by" "$deleted_proc" "$sz" "$proc_chain" \
            || result=1
        fi
      done
    fi

    # Other-volume files: mv to cross-volume ai-trash (no NSFileManager)
    if [[ ${#other_files[@]} -gt 0 ]]; then
      for f in "${other_files[@]}"; do
        local abs="" sz=""
        abs=$(realpath "$f" 2>/dev/null || echo "$f")
        [[ -f "$f" || -L "$f" ]] && sz=$(_stat_size "$f")
        _mv_file_to_ai_trash_dir "$f" "$abs" "$deleted_at" "$deleted_by" "$deleted_proc" "$sz" "$proc_chain" \
          || result=1
      done
    fi

    return $result
  fi

  # ── Linux path (unchanged): mv all files to ai-trash subdir ────────────
  for f in "$@"; do
    if [[ ! -e "$f" && ! -L "$f" ]]; then
      [[ "${has_force:-false}" != true ]] && { echo "${REAL_CMD:-rm}: $f: No such file or directory" >&2; result=1; }
      continue
    fi
    local abs="" sz=""
    abs=$(realpath "$f" 2>/dev/null || echo "$f")
    [[ -f "$f" || -L "$f" ]] && sz=$(_stat_size "$f")
    _mv_file_to_ai_trash_dir "$f" "$abs" "$deleted_at" "$deleted_by" "$deleted_proc" "$sz" "$proc_chain" \
      || result=1
  done

  return $result
}

# ─── Copy files to ai-trash as snapshots (originals stay in place) ─────
# Used by git_wrapper and find_wrapper for pre-snapshots before destructive ops.
snapshot_to_ai_trash() {
  local result=0
  local deleted_at deleted_by deleted_proc proc_chain
  deleted_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  deleted_by=$(id -un)
  deleted_proc=$(_detect_ai_process_command)
  proc_chain=$(_build_process_chain)

  for f in "$@"; do
    [[ ! -e "$f" && ! -L "$f" ]] && continue
    local abs="" sz=""
    abs=$(realpath "$f" 2>/dev/null || echo "$f")
    [[ -f "$f" || -L "$f" ]] && sz=$(_stat_size "$f")

    local trash_dir dest
    trash_dir=$(get_trash_dir "$f")
    mkdir -p "$trash_dir" 2>/dev/null || continue
    dest=$(get_unique_trash_path "$trash_dir" "$(basename "$f")")

    if cp -a "$f" "$dest" 2>/dev/null || cp -R "$f" "$dest" 2>/dev/null; then
      _write_meta "$dest" "$abs" "$deleted_at" "$deleted_by" "$deleted_proc" "$sz" "$proc_chain"
      touch "$dest" 2>/dev/null
    else
      result=1
    fi
  done
  return $result
}

# ─── Save text content as a named file in ai-trash ────────────────────
# Used by git_wrapper to save patches, SHAs, recovery hints, etc.
save_to_ai_trash() {
  local name="$1" content="$2" orig_label="$3"
  local trash_dir dest
  trash_dir="$BOOT_TRASH_DIR"
  mkdir -p "$trash_dir" 2>/dev/null || return 1
  dest=$(get_unique_trash_path "$trash_dir" "$name")
  printf '%s\n' "$content" > "$dest" || return 1

  local deleted_at deleted_by deleted_proc proc_chain sz
  deleted_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  deleted_by=$(id -un)
  deleted_proc=$(_detect_ai_process_command)
  proc_chain=$(_build_process_chain)
  sz=$(_stat_size "$dest")
  _write_meta "$dest" "$orig_label" "$deleted_at" "$deleted_by" "$deleted_proc" "$sz" "$proc_chain"
  touch "$dest" 2>/dev/null
}

# ─── Helper: check if directory is empty ───────────────────────────────
is_empty_dir() {
  local dir="$1"
  [[ -d "$dir" ]] && [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]
}
