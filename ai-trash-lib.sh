# ai-trash-lib.sh — shared library for ai-trash wrappers
# Sourced by rm_wrapper.sh, git_wrapper.sh, find_wrapper.sh, and rsync_wrapper.sh.
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

_BUILTIN_AI_ENV_VARS=(
  "TERM_PROGRAM=cursor"       # Cursor IDE
  "TERM_PROGRAM=vscode"       # VS Code (Copilot, Cline, Continue, Roo, etc.)
  "TERM_PROGRAM=windsurf"     # Windsurf (formerly Codeium)
  "TERM_PROGRAM=WarpTerminal" # Warp terminal (built-in Oz agent)
  "OPENCLAW_SHELL=exec"       # OpenClaw exec tool
  "CLAUDECODE=1"              # Claude Code shell session (set in every spawned shell)
  "CODEX_SANDBOX=seatbelt"    # OpenAI Codex CLI (set in every sandboxed subprocess on macOS)
)

_BUILTIN_AI_PROCESSES=(
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

_BUILTIN_AI_PROCESS_ARGS=(
  "codex"       # OpenAI Codex CLI   (runs as: node .../codex/...)
  "aider"       # Aider              (runs as: python3 .../aider/...)
  "gemini-cli"  # Gemini CLI via npx (runs as: node .../@google/gemini-cli/...)
  "gh copilot"  # GitHub Copilot CLI (runs as: node .../gh-copilot/...)
  "openhands"   # OpenHands          (runs as: python3 .../openhands/...)
  "opencode"    # OpenCode           (also matched by AI_PROCESSES above)
)

# ─── AI detection: builtins + your additions ───────────────────────────
# Same layering, and for the same reason, as the bypass patterns below: the
# three lists above ship in this file, which every upgrade replaces, instead of
# in config.default.sh, which the installer refuses to overwrite once a config
# exists.
#
# This half is the one that actually loses files. Before the split, a config
# written by an older release carried its own full AI_ENV_VARS=(...) assignment,
# which REPLACED the shipped list rather than adding to it. A machine whose
# config predates the CLAUDECODE=1 entry therefore stopped recognising Claude
# Code entirely: its deletes were never intercepted and went straight to
# permanent removal. Same for every AI tool added to AI_PROCESSES since.
#
# Effective list = builtins (unless disabled) - DISABLE_BUILTIN_AI_DETECTION
#                                             + your additions

# Your ADDITIONS, set in ~/.config/ai-trash/config.sh. A config written by an
# older release assigns these with its own inherited copy of the shipped lists;
# that keeps working, the entries simply repeat what the builtins already cover.
AI_ENV_VARS=()
AI_PROCESSES=()
AI_PROCESS_ARGS=()

# Turn individual builtin detection entries off, by EXACT string, across all
# three lists. The generic names are what this is for: "q" is Amazon Q Developer
# CLI to ai-trash and a different tool entirely to anyone else who has put a `q`
# on their PATH, and only the user can say which they meant.
DISABLE_BUILTIN_AI_DETECTION=()

# Master switch for the builtin detection lists.
#
# Compared with != false, the OPPOSITE of USE_BUILTIN_BYPASS_PATTERNS, and the
# asymmetry is deliberate. Detecting an AI tool ADDS protection, so an
# unreadable value must leave it ON; a bypass pattern AUTHORISES A PERMANENT
# DELETE, so an unreadable value must leave that OFF. Both directions fail
# toward keeping the user's file.
USE_BUILTIN_AI_DETECTION=${USE_BUILTIN_AI_DETECTION:-true}

# Merge helpers. macOS ships bash 3.2, which has no namerefs, so the arrays are
# passed as positional arguments and accumulated into _AIT_MERGE_RESULT. Both
# helpers drop empty entries: an empty AI_ENV_VARS entry would expand to
# ${!""} in the detection loop, and an empty AI_PROCESSES entry would become an
# empty alternative in the pipe-joined pattern awk splits.
_ait_merge_builtins() {
  local item disabled skip
  for item in "$@"; do
    [[ -z "$item" ]] && continue
    skip=false
    for disabled in "${DISABLE_BUILTIN_AI_DETECTION[@]:-}"; do
      if [[ "$item" == "$disabled" ]]; then skip=true; break; fi
    done
    [[ "$skip" == true ]] && continue
    _AIT_MERGE_RESULT+=("$item")
  done
}

_ait_merge_user() {
  local item
  for item in "$@"; do
    [[ -z "$item" ]] && continue
    _AIT_MERGE_RESULT+=("$item")
  done
}

# Collapse builtins + additions into the three arrays _is_ai_process reads.
# Called once, immediately after the user config is sourced.
_ait_build_effective_ai_detection() {
  local use="${USE_BUILTIN_AI_DETECTION:-true}"

  _AIT_MERGE_RESULT=()
  [[ "$use" != false ]] && _ait_merge_builtins "${_BUILTIN_AI_ENV_VARS[@]:-}"
  _ait_merge_user "${AI_ENV_VARS[@]:-}"
  if [[ "${#_AIT_MERGE_RESULT[@]}" -gt 0 ]]; then
    AI_ENV_VARS=("${_AIT_MERGE_RESULT[@]}")
  else
    AI_ENV_VARS=()
  fi

  _AIT_MERGE_RESULT=()
  [[ "$use" != false ]] && _ait_merge_builtins "${_BUILTIN_AI_PROCESSES[@]:-}"
  _ait_merge_user "${AI_PROCESSES[@]:-}"
  if [[ "${#_AIT_MERGE_RESULT[@]}" -gt 0 ]]; then
    AI_PROCESSES=("${_AIT_MERGE_RESULT[@]}")
  else
    AI_PROCESSES=()
  fi

  _AIT_MERGE_RESULT=()
  [[ "$use" != false ]] && _ait_merge_builtins "${_BUILTIN_AI_PROCESS_ARGS[@]:-}"
  _ait_merge_user "${AI_PROCESS_ARGS[@]:-}"
  if [[ "${#_AIT_MERGE_RESULT[@]}" -gt 0 ]]; then
    AI_PROCESS_ARGS=("${_AIT_MERGE_RESULT[@]}")
  else
    AI_PROCESS_ARGS=()
  fi
}

# New wrapper toggles — default to true, respect env overrides
GIT_PROTECTION=${GIT_PROTECTION:-true}
FIND_PROTECTION=${FIND_PROTECTION:-true}
RSYNC_PROTECTION=${RSYNC_PROTECTION:-true}
RSYNC_PROTECT_ALL_LOCAL=${RSYNC_PROTECT_ALL_LOCAL:-false}

# ─── Bypass patterns ───────────────────────────────────────────────────
# Three knobs, one effective list. The effective set is:
#
#     builtins (unless disabled) - DISABLE_BUILTIN_BYPASS_PATTERNS
#                                + BYPASS_TRASH_PATTERNS
#
# WHY THE SHIPPED DEFAULTS LIVE HERE AND NOT IN config.default.sh:
# install.sh writes ~/.config/ai-trash/config.sh only when that file does not
# already exist, and leaves it untouched otherwise, because a user's config is
# theirs to own. Anything shipped inside that template therefore reaches new
# installs only, and freezes at v1 on every machine that has ever upgraded. Two
# releases' worth of new defaults reached nobody that way, including the Claude
# Code snapshot pattern below that accounted for 90.4% of trashed items on a
# measured host. Keeping the defaults in a file the installer DOES overwrite
# makes "a new shipped default never reaches existing users" impossible by
# construction, rather than something an upgrade-time merge heuristic has to
# re-derive correctly on every release.
#
# The config file is a persisted-format contract, so this stays additive: a
# config written by any earlier version still parses, and its full inherited
# copy of the old defaults simply matches redundantly alongside the builtins.

# _BUILTIN_BYPASS_PATTERNS - shipped defaults. Files whose resolved absolute
# path matches any entry are permanently deleted (/bin/rm) instead of going to
# ai-trash, because they have zero recovery value. Entries are extended regular
# expressions (ERE), matched with bash =~; an entry without ^ or $ matches
# anywhere in the path. Do not edit this array to customise: it is overwritten
# on every upgrade. Use the three config knobs below instead.
_BUILTIN_BYPASS_PATTERNS=(
  # macOS temp dirs - mktemp outputs; cleaned by OS on reboot
  "^/private/var/folders/"
  "^/var/folders/"
  "^/private/tmp/"
  "^/tmp/"

  # macOS system Trash - mktemp-style ephemeral files that ended up in ~/.Trash
  # (common in safe mode when tools delete temp files). Never worth recovering.
  "$HOME/\.Trash/tmp\."

  # Git transient lock and state files - contain no data, never worth restoring
  "/\.git/index\.lock$"
  "/\.git/MERGE_HEAD$"
  "/\.git/CHERRY_PICK_HEAD$"
  "/\.git/REVERT_HEAD$"
  "/\.git/BISECT_HEAD$"
  "/\.git/ORIG_HEAD$"

  # ── AI coding tool ephemeral state ──────────────────────────────────
  # These are the highest-volume deletions on a machine that runs AI coding
  # agents all day, which is exactly the machine ai-trash is installed on.
  # Without these patterns the trash fills with tool bookkeeping rather than
  # the user work it exists to protect.

  # Claude Code's pre-Bash git snapshot: one written and deleted per Bash
  # tool call, per session. On a measured machine these were 66,098 of
  # 73,121 trashed items (90.4%) over a single retention window. Pure
  # ephemeral tool state that is never restored.
  # The (.*/)? is load-bearing: in a linked worktree or a submodule these
  # live under .git/worktrees/<name>/ or .git/modules/<name>/, not directly
  # under .git/. Scoping to .git/ keeps a user file that happens to share
  # the name out of the bypass.
  "/\.git/(.*/)?\.claude-bash-pre-[0-9a-f-]+\.snapshot$"

  # Aider repo-map cache, rebuilt from source on the next aider run
  "/\.aider\.tags\.cache\.v[0-9]+(/|$)"

  # Claude desktop app Electron caches, rebuilt on next launch.
  # "Code Cache" needs its own entry: its path does not contain "/Claude/Cache".
  "$HOME/Library/Application Support/Claude/Cache"
  "$HOME/Library/Application Support/Claude/Code Cache"

  # pyenv shims - auto-generated by pyenv; recreated instantly with pyenv rehash
  "/\.pyenv/shims/"

  # ssh-copy-id temp files - ephemeral, created and discarded by the command
  "/\.ssh/ssh-copy-id\."

  # node_modules - reinstalled instantly with npm/yarn/bun install; never worth recovering
  "/node_modules/"

  # Playwright browser binaries (chromium, webkit, firefox) - large, auto-downloaded on demand
  "/ms-playwright/"

  # Gradle daemon - process lock/state files, auto-recreated on next build
  "/\.gradle/daemon"

  # macOS .framework bundles - system/Xcode artifacts, large, managed by the OS
  "\.framework(/|$)"

  # Xcode provisioning profiles - code-signing artifacts, auto-managed by Xcode
  "\.provisionprofile$"

  # Python bytecode - auto-generated, recreated on import
  "__pycache__(/|$)"
  "\.pyc$"

  # macOS Finder metadata - auto-recreated when opening any folder
  "\.DS_Store$"

  # Xcode build intermediates and test result bundles
  "/DerivedData/"
  "\.xcresult(/|$)"

  # React Native / Expo iOS build output, regenerated on next build
  "/ios/build(/|$)"

  # Gradle build output (Android), regenerated on next build
  "/android/app/build(/|$)"
  "/build/android(/|$)"

  # Mobile test/build artifacts that are regenerated by local verification runs
  "/build/PrefixCheckDD(/|$)"
  "/\.e2e-logs/detox-[^/]*\.log$"
  "/artifacts/ios\.sim\.debug\."
  "/tmp/jest(/|$)"
  "/thumbcache(/|$)"

  # Xcode "do not index" caches: ModuleCache.noindex, Index.noindex,
  # CompilationCache.noindex, SDKStatCaches.noindex. Pure caches, regenerated
  # on next build. Catches DerivedData-shaped trees with non-standard names.
  "\.noindex(/|$)"

  # Java compiled bytecode - always regenerated from .java source
  "\.class$"

  # Python tool caches and packaging metadata
  "/\.pytest_cache(/|$)"
  "/\.mypy_cache(/|$)"
  "\.egg-info(/|$)"
  "/\.tox(/|$)"
  "/\.nox(/|$)"

  # CocoaPods dependencies - regenerated by pod install
  "/Pods(/|$)"

  # CocoaPods global cache - auto-downloaded on demand by pod install
  "/Library/Caches/CocoaPods/"

  # Vim swap files - ephemeral editor state
  "\.swp$"
  "\.swo$"

  # Ruby Bundler - regenerated by bundle install
  "/vendor/bundle/"

  # Autoconf/configure artifacts - created and deleted thousands of times per
  # ./configure run. Ephemeral test programs, objects, and temp files with zero
  # recovery value.
  "/conftest$"
  "/conftest\."
  "/conftest[0-9]"
  "/confdefs\.h$"
  "/confcache$"
  "/confinc\."
  "/confmf\."
  "/conf[0-9][0-9]*"
  "/libconftest\."
  "/conftstm\."

  # Default compiler output, never intentionally named
  "/a\.out$"

  # Swift Package Manager build output, regenerated by swift build
  "\.build(/|$)"

  # JS framework build/cache dirs, regenerated by dev/build commands
  "/\.next(/|$)"
  "/\.nuxt(/|$)"
  "/\.parcel-cache(/|$)"
  "/\.svelte-kit(/|$)"
  "/\.angular/cache(/|$)"
  "/\.turbo(/|$)"

  # Flutter/Dart generated build state, regenerated by pub get / flutter build
  "/\.dart_tool(/|$)"

  # Terraform provider/module cache, regenerated by terraform init
  "/\.terraform(/|$)"

  # CMake build artifacts, regenerated by cmake configure/build
  "/cmake-build-[^/]+(/|$)"
  "/CMakeFiles(/|$)"
  "/CMakeCache\.txt$"

  # Bazel build outputs, regenerated by bazel build/test
  "/bazel-(bin|out|testlogs)(/|$)"

  # Buck/Buck2 build output, regenerated by buck build
  "/buck-out(/|$)"

  # Android NDK/Gradle native CMake intermediates, regenerated by Gradle
  "/\.cxx(/|$)"

  # Gradle project-local caches (excludes wrapper config/scripts)
  "/\.gradle/caches(/|$)"
  "/\.gradle/buildOutputCleanup(/|$)"
  "/\.gradle/configuration-cache(/|$)"

  # Gradle buildSrc compiled output, regenerated by Gradle
  "/buildSrc/build(/|$)"

  # Maven wrapper downloaded distributions, regenerated by mvnw
  "/\.mvn/wrapper/dists(/|$)"

  # Serverless Framework deployment artifacts, regenerated by sls package
  "/\.serverless(/|$)"

  # AWS SAM build artifacts, regenerated by sam build
  "/\.aws-sam(/|$)"

  # AWS CDK synthesized output, regenerated by cdk synth
  "/cdk\.out(/|$)"

  # Sass compiler cache, regenerated on build
  "/\.sass-cache(/|$)"

  # NYC/Istanbul coverage data, regenerated by test runs
  "/\.nyc_output(/|$)"
)

# ─── User overrides (set in ~/.config/ai-trash/config.sh) ──────────────

# BYPASS_TRASH_PATTERNS - your ADDITIONS to the builtin list. Same ERE syntax.
# `ai-trash suggest` prints ready-to-paste entries for this array. A config
# written before the builtins existed holds a full copy of the old defaults
# here; that keeps working, it just matches the same paths twice.
BYPASS_TRASH_PATTERNS=()

# DISABLE_BUILTIN_BYPASS_PATTERNS - turn individual builtins off, by EXACT
# pattern string. Copy the string to disable from `ai-trash bypass-patterns`,
# which prints the effective list and flags entries here that match no builtin.
DISABLE_BUILTIN_BYPASS_PATTERNS=()

# USE_BUILTIN_BYPASS_PATTERNS - master switch. Set to false to ignore the whole
# builtin list and bypass only what BYPASS_TRASH_PATTERNS names. This preserves
# the pre-builtins capability of running with no bypass patterns at all, which
# an exact-string disable list cannot express.
#
# Compared with == true, the same idiom the GIT_PROTECTION / FIND_PROTECTION /
# RSYNC_PROTECTION toggles use, so an unrecognised value ("TRUE", "yes", a typo)
# leaves the builtins OFF rather than on. Bypassing means PERMANENT deletion, so
# a config in an unknown state must not authorise it; the cost of the safe
# direction is a fuller trash, which is recoverable, and `ai-trash
# bypass-patterns` reports the unrecognised value rather than swallowing it.
# An ABSENT key still means on, which is what makes pre-builtin configs work.
USE_BUILTIN_BYPASS_PATTERNS=${USE_BUILTIN_BYPASS_PATTERNS:-true}

# _ait_build_effective_bypass_patterns - collapse the three knobs above into the
# single list _matches_bypass_pattern walks. Called once, immediately after the
# user config is sourced, so the per-delete hot path never re-derives it.
_ait_build_effective_bypass_patterns() {
  local pattern disabled skip
  _AIT_EFFECTIVE_BYPASS_PATTERNS=()

  if [[ "${USE_BUILTIN_BYPASS_PATTERNS:-true}" == true ]]; then
    for pattern in "${_BUILTIN_BYPASS_PATTERNS[@]:-}"; do
      [[ -z "$pattern" ]] && continue
      skip=false
      for disabled in "${DISABLE_BUILTIN_BYPASS_PATTERNS[@]:-}"; do
        if [[ "$pattern" == "$disabled" ]]; then skip=true; break; fi
      done
      [[ "$skip" == true ]] && continue
      _AIT_EFFECTIVE_BYPASS_PATTERNS+=("$pattern")
    done
  fi

  for pattern in "${BYPASS_TRASH_PATTERNS[@]:-}"; do
    [[ -z "$pattern" ]] && continue
    _AIT_EFFECTIVE_BYPASS_PATTERNS+=("$pattern")
  done
}

# Load user config - sourced so it overrides the defaults above.
# To customise, edit: ~/.config/ai-trash/config.sh
# shellcheck source=/dev/null
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Must run AFTER the config source: the config is what supplies the additions,
# the disable list, and the master switch.
_ait_build_effective_bypass_patterns
_ait_build_effective_ai_detection


# ─── Real-binary resolution + recursion guard (shared across all wrappers) ──
# Single source of truth for two things that used to be copy-pasted (and had
# DIVERGED) into each wrapper, which is how the 2026-06-14 CPU spin happened
# (see memory/git_wrapper_thundering_herd.md): two script-based git wrappers on
# PATH each resolved "the real git" differently, one without a magic-byte check,
# so they re-exec'd each other unbounded and pinned a core.
#
# These run AFTER each wrapper's inline fd-close (which must stay inline because
# it has to execute before the first fork). By the time a wrapper sources this
# library and calls these, leaked pipe fds are already closed, so the command
# substitutions below cannot deadlock.

# _ait_resolve_real <name> — echo the absolute path of the real <name> binary.
# INVARIANT enforced structurally: the result is ALWAYS a compiled binary whose
# first two bytes are not '#!', never a shell-script wrapper. This makes
# wrapper-into-wrapper mutual recursion impossible regardless of PATH order.
# Walks PATH first, then a standard fallback set. Skips any candidate that is
# (a) a symlink resolving to a *_wrapper.sh, or (b) a '#!' script of any kind.
# Returns 127 and prints to stderr if no real binary is found.
# Usage: REAL_GIT=$(_ait_resolve_real git)
_ait_resolve_real() {
  local name="$1" dir candidate _magic
  local -a dirs=()
  local IFS=:
  read -ra dirs <<<"$PATH"
  IFS=' '
  dirs+=(/opt/homebrew/bin /usr/local/bin /usr/bin /bin)
  for dir in "${dirs[@]}"; do
    [[ -n "$dir" && -x "$dir/$name" && ! -d "$dir/$name" ]] || continue
    candidate="$dir/$name"
    while [[ -L "$candidate" ]]; do candidate=$(readlink "$candidate"); done
    [[ "${candidate##*/}" == *_wrapper.sh ]] && continue   # never our own wrapper
    # Read the magic byte from the PATH entry itself (the OS follows the link),
    # not the possibly-relative readlink target which may not resolve from CWD.
    _magic=""; read -rn2 _magic 2>/dev/null < "$dir/$name" || true
    [[ "$_magic" == '#!' ]] && continue                    # never ANY script wrapper
    printf '%s' "$dir/$name"
    return 0
  done
  echo "ai-trash: cannot find real $name binary" >&2
  return 127
}

# _ait_break_to_real <name> [args...] — exec the real <name> binary and stop.
# Used by the recursion guard to escape a detected loop. Falls back to
# /usr/bin/<name> only if resolution fails entirely.
_ait_break_to_real() {
  local name="$1"; shift
  local real
  real=$(_ait_resolve_real "$name") && exec "$real" "$@"
  exec "/usr/bin/$name" "$@"
}

# _ait_recursion_guard <tag> <name> [args...] — belt + suspenders against
# wrapper-into-wrapper mutual re-exec. Mirrored (with a different tag) in the
# cross-agent shim at ~/.claude/bin/git, which cannot source this library.
#   Belt (prevent):   if THIS wrapper's <tag> is already in AI_GIT_WRAPPER_CHAIN
#                     we are being recursed into -> break out to a real binary.
#   Suspenders (bail): if depth in AI_GIT_WRAPPER_DEPTH ever exceeds 8, bail to a
#                     real binary instead of spinning forever.
# The AI_GIT_WRAPPER_* names are kept (despite being git-flavoured) so the shim,
# which already uses them, stays interoperable. The depth counter is shared
# across all wrappers; the tag is per-command so each detects only its own loop.
_ait_recursion_guard() {
  local tag="$1" name="$2"; shift 2
  AI_GIT_WRAPPER_DEPTH=$(( ${AI_GIT_WRAPPER_DEPTH:-0} + 1 ))
  export AI_GIT_WRAPPER_DEPTH
  case ":${AI_GIT_WRAPPER_CHAIN:-}:" in
    *":$tag:"*) _ait_break_to_real "$name" "$@" ;;
  esac
  (( AI_GIT_WRAPPER_DEPTH > 8 )) && _ait_break_to_real "$name" "$@"
  export AI_GIT_WRAPPER_CHAIN="${AI_GIT_WRAPPER_CHAIN:+$AI_GIT_WRAPPER_CHAIN:}$tag"
}

# ─── Selective mode: detect AI tool in the process call chain ──────────
_is_ai_process() {
  # Tier 1: environment variable check — instant, no process lookup needed
  local var val env_check
  for env_check in "${AI_ENV_VARS[@]:-}"; do
    [[ -z "$env_check" ]] && continue
    var="${env_check%%=*}"
    val="${env_check#*=}"
    [[ "${!var:-}" == "$val" ]] && return 0
  done

  # Tier 1.5: PPID-keyed file cache.
  # When a build tool (make, configure) calls rm hundreds of times, every call
  # has the same PPID and the same process ancestry. Cache the Tier 2 result so
  # only the first call pays the ps|awk cost; subsequent calls read a tiny file.
  # Format: "<exit_code> <parent_comm>" — comm is checked to guard against PID
  # reuse (different process reusing the same PID would have a different comm).
  local _cache="/tmp/.ai-trash-detect-$PPID"
  if [[ -f "$_cache" ]]; then
    local _cached_result _cached_comm _current_comm
    read -r _cached_result _cached_comm < "$_cache" 2>/dev/null
    _current_comm=$(ps -p $PPID -o comm= 2>/dev/null)
    if [[ "$_cached_comm" == "$_current_comm" ]]; then
      return "$_cached_result"
    fi
    /bin/rm -f "$_cache"
  fi

  # Tier 2: single-fork process tree walk.
  # Does the entire ancestor walk inside one ps|awk pipeline instead of forking
  # awk/ps per ancestor (which cost ~0.5-0.7s per rm call).
  local IFS='|'
  local procs_str="${AI_PROCESSES[*]}"
  local args_str="${AI_PROCESS_ARGS[*]}"
  IFS=' '

  ps -A -o pid=,ppid=,comm=,args= 2>/dev/null | awk \
    -v "start=$$" \
    -v "procs=$procs_str" \
    -v "apats=$args_str" '
    BEGIN { np=split(procs,p,"|"); na=split(apats,a,"|") }
    {
      id=$1+0; pp[id]=$2+0; cm[id]=$3
      # args = everything after the 3rd whitespace-delimited field
      match($0, /^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]*/)
      ar[id]=substr($0, RLENGTH+1)
    }
    END {
      pid=start+0
      while(pid>1) {
        if(!(pid in cm)) exit 1
        for(i=1;i<=np;i++) if(cm[pid]==p[i]) { exit 0 }
        if(na>0) for(i=1;i<=na;i++) if(index(ar[pid],a[i])>0) { exit 0 }
        if(pp[pid]<=1 || pp[pid]==pid) break
        pid=pp[pid]
      }
      exit 1
    }'
  local _result=$?

  # Cache the result keyed on PPID + parent's comm name
  local _parent_comm
  _parent_comm=$(ps -p $PPID -o comm= 2>/dev/null)
  printf '%d %s\n' "$_result" "$_parent_comm" > "$_cache" 2>/dev/null

  return "$_result"
}

# ─── Identify the AI process that triggered this deletion ─────────────
# Walks the process tree (like _is_ai_process) and prints the full command
# line of the first matched AI ancestor. Falls back to the immediate parent.
_detect_ai_process_command() {
  # Check env-var tier first — if matched, the parent is the calling shell,
  # so walk up to grandparent for a more useful label.
  local var val env_check
  for env_check in "${AI_ENV_VARS[@]:-}"; do
    [[ -z "$env_check" ]] && continue
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

  # Walk the process tree looking for the AI ancestor (single-fork).
  local IFS='|'
  local procs_str="${AI_PROCESSES[*]}"
  local args_str="${AI_PROCESS_ARGS[*]}"
  IFS=' '

  local result
  result=$(ps -A -o pid=,ppid=,comm=,args= 2>/dev/null | awk \
    -v "start=$$" \
    -v "ppid_hint=$PPID" \
    -v "procs=$procs_str" \
    -v "apats=$args_str" '
    BEGIN { np=split(procs,p,"|"); na=split(apats,a,"|") }
    {
      id=$1+0; pp[id]=$2+0; cm[id]=$3
      match($0, /^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]*/)
      ar[id]=substr($0, RLENGTH+1)
    }
    END {
      pid=start+0
      while(pid>1) {
        if(!(pid in cm)) break
        c=cm[pid]
        for(i=1;i<=np;i++) if(c==p[i]) { sub(/^[[:space:]]+/,"",ar[pid]); print ar[pid]; exit 0 }
        if(na>0) { a_str=ar[pid]; for(i=1;i<=na;i++) if(index(a_str,a[i])>0) { sub(/^[[:space:]]+/,"",a_str); print a_str; exit 0 } }
        if(pp[pid]<=1 || pp[pid]==pid) break
        pid=pp[pid]
      }
      # Fallback: parent command
      if(ppid_hint+0 in ar) {
        cmd=ar[ppid_hint+0]
        sub(/^[[:space:]]+/,"",cmd)
        sub(/^-/,"",cmd)
        if(cmd!="") print cmd " (unknown)"
        else print "unknown"
      } else print "unknown"
      exit 1
    }') && { printf '%s' "$result"; return; }

  # awk returned non-zero — result is the fallback label
  if [[ -n "$result" ]]; then
    printf '%s' "$result"
  else
    printf 'unknown'
  fi
}

# ─── Build the full process ancestor chain for forensics ─────────────
# Returns full command lines: "bash /Users/user/bin/q list > zsh > claude > ..."
_build_process_chain() {
  # Single-fork: builds the full ancestor chain inside one ps|awk pipeline.
  # For interpreters (bash, python3, node, etc.) includes the script argument.
  ps -A -o pid=,ppid=,comm=,args= 2>/dev/null | awk \
    -v "start=$$" '
    BEGIN {
      split("bash sh zsh dash fish python python3 node ruby perl", interps, " ")
      for(i in interps) is_interp[interps[i]]=1
    }
    {
      id=$1+0; pp[id]=$2+0
      c=$3; sub(/.*\//,"",c); sub(/^-/,"",c)
      cm[id]=c
      match($0, /^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]*/)
      a=substr($0, RLENGTH+1)
      sub(/^[[:space:]]+/,"",a); sub(/^-/,"",a)
      ar[id]=a
    }
    END {
      chain=""
      pid=start+0
      while(pid>1) {
        if(!(pid in cm)) break
        c=cm[pid]
        if(c in is_interp && ar[pid]!="" && length(ar[pid])<=120 && ar[pid]!=c)
          label=ar[pid]
        else
          label=c
        if(chain!="") chain=chain " > "
        chain=chain label
        if(pp[pid]<=1 || pp[pid]==pid) break
        pid=pp[pid]
      }
      printf "%s", chain
    }'
}

# ─── Bypass pattern check ──────────────────────────────────────────────
# Returns 0 if the resolved absolute path matches any effective bypass entry.
# The effective list is built once at load time by
# _ait_build_effective_bypass_patterns from _BUILTIN_BYPASS_PATTERNS,
# DISABLE_BUILTIN_BYPASS_PATTERNS and the user's BYPASS_TRASH_PATTERNS; reading
# it here rather than re-deriving it keeps the per-delete hot path a single loop.
# Patterns are ERE matched with bash =~. $HOME is already expanded at config
# source time when patterns are written with double-quoted "$HOME/..." syntax.
_matches_bypass_pattern() {
  local abs="$1" pattern
  for pattern in "${_AIT_EFFECTIVE_BYPASS_PATTERNS[@]:-}"; do
    [[ -z "$pattern" ]] && continue
    [[ "$abs" =~ $pattern ]] && return 0
  done
  return 1
}

# ─── Platform helpers ──────────────────────────────────────────────────
_stat_dev()  { [[ "$PLATFORM" == "Darwin" ]] && stat -f %d "$1" 2>/dev/null || stat -c %d "$1" 2>/dev/null; }
_stat_size() { [[ "$PLATFORM" == "Darwin" ]] && stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null; }

# ─── Sidecar metadata (Linux only) ─────────────────────────────────────
# macOS stores per-item metadata in extended attributes, so a trashed item is
# a single filesystem entry. Linux has no xattr dependency, so metadata lives
# in a sibling dotfile ".<name>.ai-trash" inside the same trash directory.
#
# That sidecar is bookkeeping ABOUT a trashed item, never a trashed item
# itself. Two invariants follow, and both must hold at every call site:
#   1. It is excluded from any enumeration of trash contents (list, status,
#      empty, cleanup inventory), or it shows up as a bogus zero-metadata
#      entry and is counted, evicted, and purged as though it were user data.
#   2. It is removed with its item. Removing the item alone orphans the
#      sidecar in the trash directory permanently: nothing else ever
#      references it, and every later enumeration has to filter it out.
# Route every removal through _remove_trash_item so 2 cannot be forgotten.

# Path of the sidecar metadata file belonging to a trashed item.
_meta_path() { printf '%s/.%s.ai-trash' "${1%/*}" "${1##*/}"; }

# True when a path is a sidecar metadata file rather than a trashed item.
_is_meta_path() { [[ "${1##*/}" == .*.ai-trash ]]; }

# Permanently remove a trashed item together with its sidecar metadata.
# Safe on macOS, where there is no sidecar to remove.
_remove_trash_item() {
  local item="$1"
  /bin/rm -rf "$item"
  if [[ "$PLATFORM" != "Darwin" ]]; then
    /bin/rm -f "$(_meta_path "$item")" 2>/dev/null || true
  fi
  return 0
}

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
      > "$(_meta_path "$file")" 2>/dev/null || true
  fi
}

_write_meta_field() {
  local file="$1" key="$2" value="$3"
  [[ -z "$value" ]] && return 0
  if [[ "$PLATFORM" == "Darwin" ]]; then
    xattr -w "com.ai-trash.$key" "$value" "$file" >/dev/null 2>&1 || true
  else
    printf '%s=%s\n' "$key" "$value" >> "$(_meta_path "$file")" 2>/dev/null || true
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

    if _matches_bypass_pattern "$abs"; then
      if [[ -d "$f" ]]; then /bin/rm -rf "$f"; else /bin/rm -f "$f"; fi
      continue
    fi

    if [[ -d "$f" ]] && is_empty_dir "$f"; then
      /bin/rmdir "$f"
      continue
    fi

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

    dest=$(get_unique_trash_path "$trash_dir" "${f##*/}")
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
  dest=$(get_unique_trash_path "$trash_dir" "${f##*/}")
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

      if _matches_bypass_pattern "$abs"; then
        if [[ -d "$f" ]]; then /bin/rm -rf "$f"; else /bin/rm -f "$f"; fi
        continue
      fi

      if [[ -d "$f" ]] && is_empty_dir "$f"; then
        /bin/rmdir "$f"
        continue
      fi

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

    if _matches_bypass_pattern "$abs"; then
      if [[ -d "$f" ]]; then /bin/rm -rf "$f"; else /bin/rm -f "$f"; fi
      continue
    fi

    if [[ -d "$f" ]] && is_empty_dir "$f"; then
      /bin/rmdir "$f"
      continue
    fi

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
    dest=$(get_unique_trash_path "$trash_dir" "${f##*/}")

    if cp -a "$f" "$dest" 2>/dev/null || cp -R "$f" "$dest" 2>/dev/null; then
      _write_meta "$dest" "$abs" "$deleted_at" "$deleted_by" "$deleted_proc" "$sz" "$proc_chain"
      touch "$dest" 2>/dev/null
    else
      result=1
    fi
  done
  return $result
}

# ─── Import rsync --backup-dir output into ai-trash ───────────────────
# Rsync writes pre-change destination files into a staging backup directory.
# Move those backups into normal ai-trash storage and record the original
# destination path so the existing restore command can put them back.
import_rsync_backup_dir_to_ai_trash() {
  local backup_dir="$1" dest_root="$2" dest_is_dir="${3:-true}" suffix="${4:-}"
  local result=0

  [[ -d "$backup_dir" ]] || return 0

  local deleted_at deleted_by deleted_proc proc_chain
  deleted_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  deleted_by=$(id -un)
  deleted_proc=$(_detect_ai_process_command)
  proc_chain=$(_build_process_chain)

  local -a items=()
  while IFS= read -r -d '' item; do
    items+=("$item")
  done < <(find "$backup_dir" -mindepth 1 ! -type d -print0 2>/dev/null)

  local item rel orig_path sz trash_base trash_dir dest
  for item in "${items[@]}"; do
    rel="${item#$backup_dir/}"
    [[ -n "$suffix" && "$rel" == *"$suffix" ]] && rel="${rel%"$suffix"}"

    if [[ "$dest_is_dir" == true ]]; then
      orig_path="${dest_root%/}/$rel"
    elif [[ "$rel" == "$(basename "$dest_root")" ]]; then
      orig_path="$dest_root"
    else
      orig_path="${dest_root%/}/$rel"
    fi

    if _matches_bypass_pattern "$orig_path"; then
      /bin/rm -f "$item" 2>/dev/null || true
      continue
    fi

    sz=""
    [[ -f "$item" || -L "$item" ]] && sz=$(_stat_size "$item")

    trash_base="$dest_root"
    [[ -e "$trash_base" || -L "$trash_base" ]] || trash_base="$HOME"
    trash_dir=$(get_trash_dir "$trash_base")
    if ! mkdir -p "$trash_dir" 2>/dev/null; then
      result=1
      continue
    fi

    dest=$(get_unique_trash_path "$trash_dir" "$(basename "$orig_path")")
    if mv "$item" "$dest"; then
      _write_meta "$dest" "$orig_path" "$deleted_at" "$deleted_by" "$deleted_proc" "$sz" "$proc_chain"
      _write_meta_field "$dest" "operation" "rsync-backup"
      touch "$dest" 2>/dev/null
    else
      result=1
    fi
  done

  /bin/rm -rf "$backup_dir" 2>/dev/null || true
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
  [[ ! -L "$dir" ]] && [[ -d "$dir" ]] && [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]
}
