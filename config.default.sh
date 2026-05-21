# ai-trash configuration
# Installed to: ~/.config/ai-trash/config
# ---------------------------------------------------------------------------
# This file is sourced as bash. Changes take effect immediately — no restart
# needed. Lines starting with # are comments and have no effect.
# ---------------------------------------------------------------------------


# PROTECTION MODE
# ---------------
# Controls which rm calls ai-trash intercepts.
#
#   selective  (default) — only intercept rm when an AI tool is detected
#                          anywhere in the process call chain. Your own rm
#                          commands pass straight through to /bin/rm unchanged,
#                          exactly as if ai-trash weren't installed.
#                          Best for: developers who trust their own rm usage
#                          and only want protection from AI tools.
#
#   safe                 — AI calls go to ai-trash (with full metadata).
#                          Non-AI CLI calls go to the regular macOS Trash
#                          (~/.Trash) instead of being permanently deleted.
#                          Nothing typed at a terminal ever vanishes silently.
#                          Items from non-AI rm won't appear in `ai-trash list`
#                          but are recoverable via Finder like any Trash item.
#                          Best for: anyone who wants a complete safety net
#                          without polluting ai-trash with their own deletions.
#
MODE=selective
# MODE=safe


# FAST PATH  (selective mode only)
# ------------------------------------------------
# When enabled (default), rm/rmdir/unlink bypass the full process-tree
# detection when no AI environment variables are set. This makes builds
# (~./configure, make) almost instant but means standalone AI tools that
# only set process names — not env vars — (aider, goose, etc.) won't be
# detected. All major AI platforms (Claude Code, VS Code, Cursor, Windsurf,
# Codex, Warp) set env vars and are always detected regardless.
#
# Set to false if you use a Tier-2-only AI tool and want full detection.
# FAST_PATH=false


# AI ENVIRONMENT VARIABLES  (selective mode only)
# ------------------------------------------------
# Checked before any process lookup — zero performance overhead.
# Format: "VAR_NAME=value"  (exact match on the value)
#
# IDE-integrated terminals set TERM_PROGRAM to identify themselves. If your
# AI tool's terminal isn't listed, add it here. To find the right value, open
# a terminal inside your tool and run:  echo $TERM_PROGRAM
#
AI_ENV_VARS=(
  "TERM_PROGRAM=cursor"       # Cursor IDE
  "TERM_PROGRAM=vscode"       # VS Code — covers GitHub Copilot, Cline,
                              #   Continue.dev, Roo, and any other VS Code extension
  "TERM_PROGRAM=windsurf"     # Windsurf (formerly Codeium)
  "TERM_PROGRAM=WarpTerminal" # Warp terminal — covers the built-in Oz agent
                              #   and any CLI agent run inside Warp
  "OPENCLAW_SHELL=exec"       # OpenClaw — set by its exec tool when running shell commands
  "CLAUDECODE=1"              # Claude Code — set in every shell session it spawns
  "CODEX_SANDBOX=seatbelt"    # OpenAI Codex CLI — set in every sandboxed subprocess on macOS
)


# AI PROCESS NAMES  (selective mode only)
# ----------------------------------------
# Matched against the executable name (basename) at every level of the
# process tree, walking all the way up to launchd (PID 1).
#
# Use this for tools that ship as their own named binary.
# To find the right name, run the tool and check:  ps aux | grep <toolname>
#
AI_PROCESSES=(
  claude      # Claude Code (Anthropic)
  gemini      # Gemini CLI (Google) — standalone binary install
  goose       # Goose (Block/Square)
  opencode    # OpenCode — open-source Claude Code alternative
  aider       # Aider — when installed as a standalone script (pip install aider-chat)
  devin       # Devin (Cognition)
  kiro-cli    # Kiro CLI (AWS) — formerly Amazon Q Developer CLI
  q           # Amazon Q Developer CLI — pre-Kiro rebrand (still in wide use)
  openclaw    # OpenClaw — self-hosted AI assistant gateway
  cline       # Cline — standalone CLI (VS Code extension covered by TERM_PROGRAM=vscode)
  plandex     # Plandex — large-context terminal agent
  crush       # Crush — terminal agent by Charm
  qodo        # Qodo Command — workflow automation agent
)


# AI PROCESS ARGS  (selective mode only)
# ----------------------------------------
# Substring-matched against the full command line at every level of the
# process tree. Use this for tools that run inside node, python, etc., where
# the process name alone is just "node" or "python3" and isn't enough.
#
# Each entry is a plain substring — no glob or regex. Keep patterns specific
# enough to avoid matching unrelated processes (e.g. "aider" is fine;
# "ai" would be too broad).
#
AI_PROCESS_ARGS=(
  "codex"       # OpenAI Codex CLI      (runs as: node .../codex/...)
  "aider"       # Aider                 (runs as: python3 .../aider/... — belt+suspenders
                #                        with the AI_PROCESSES entry above)
  "gemini-cli"  # Gemini CLI via npx    (runs as: node .../@google/gemini-cli/...)
  "gh copilot"  # GitHub Copilot CLI    (runs as: node .../gh-copilot/...)
  "openhands"   # OpenHands             (runs as: python3 .../openhands/...)
  "opencode"    # OpenCode              (belt+suspenders with AI_PROCESSES above)
)


# GIT PROTECTION
# ---------------
# When true, ai-trash intercepts destructive git commands from AI callers:
#   git clean -fd, git checkout -- ., git restore ., git reset --hard,
#   git stash drop/clear, git branch -D, git push --force, git filter-repo
#
# Affected files are snapshotted to ai-trash BEFORE the git command runs.
# Non-AI callers and non-destructive git commands are never affected.
#
GIT_PROTECTION=true
# GIT_PROTECTION=false


# FIND PROTECTION
# ----------------
# When true, ai-trash intercepts "find -delete" from AI callers by replacing
# -delete with "-exec rm {} +" which routes through the rm wrapper.
# Non-AI callers are never affected.
#
FIND_PROTECTION=true
# FIND_PROTECTION=false


# RSYNC PROTECTION
# -----------------
# When true, ai-trash intercepts AI-originated local rsync commands that can
# delete destination files, runs them with rsync backups enabled, and imports
# deleted/replaced destination files into ai-trash.
# Commands that already specify --backup, --no-backup, or --backup-dir pass
# through unchanged. Remote destinations pass through unchanged.
#
RSYNC_PROTECTION=true
# RSYNC_PROTECTION=false

# By default, only delete-capable rsync commands are protected. Set this to true
# to preserve overwritten destination files for any AI-originated local rsync.
#
RSYNC_PROTECT_ALL_LOCAL=false
# RSYNC_PROTECT_ALL_LOCAL=true


# BYPASS TRASH PATTERNS
# ----------------------
# Files whose resolved absolute path matches any pattern here are permanently
# deleted (/bin/rm) instead of going to ai-trash. Use this for files that have
# zero recovery value so they don't bloat the trash.
#
# Patterns are extended regular expressions (ERE), matched with bash =~.
# $HOME is expanded at config-load time when written inside double quotes.
# A pattern without ^ or $ anchors matches anywhere in the path.
#
BYPASS_TRASH_PATTERNS=(
  # macOS temp dirs — mktemp outputs; cleaned by OS on reboot
  "^/private/var/folders/"
  "^/var/folders/"
  "^/private/tmp/"
  "^/tmp/"

  # macOS system Trash — mktemp-style ephemeral files that ended up in ~/.Trash
  # (common in safe mode when tools delete temp files). Never worth recovering.
  "$HOME/\.Trash/tmp\."

  # Git transient lock and state files — contain no data, never worth restoring
  "/\.git/index\.lock$"
  "/\.git/MERGE_HEAD$"
  "/\.git/CHERRY_PICK_HEAD$"
  "/\.git/REVERT_HEAD$"
  "/\.git/BISECT_HEAD$"
  "/\.git/ORIG_HEAD$"

  # pyenv shims — auto-generated by pyenv; recreated instantly with pyenv rehash
  "/\.pyenv/shims/"

  # ssh-copy-id temp files — ephemeral, created and discarded by the command
  "/\.ssh/ssh-copy-id\."

  # node_modules — reinstalled instantly with npm/yarn/bun install; never worth recovering
  "/node_modules/"

  # Playwright browser binaries (chromium, webkit, firefox) — large, auto-downloaded on demand
  "/ms-playwright/"

  # Gradle daemon — process lock/state files, auto-recreated on next build
  "/\.gradle/daemon"

  # macOS .framework bundles — system/Xcode artifacts, large, managed by the OS
  "\.framework(/|$)"

  # Xcode provisioning profiles — code-signing artifacts, auto-managed by Xcode
  "\.provisionprofile$"

  # Python bytecode — auto-generated, recreated on import
  "__pycache__(/|$)"
  "\.pyc$"

  # macOS Finder metadata — auto-recreated when opening any folder
  "\.DS_Store$"

  # Xcode build intermediates and test result bundles
  "/DerivedData/"
  "\.xcresult(/|$)"

  # React Native / Expo iOS build output, regenerated on next build
  "/ios/build(/|$)"

  # Gradle build output (Android), regenerated on next build
  "/android/app/build(/|$)"

  # Xcode "do not index" caches: ModuleCache.noindex, Index.noindex,
  # CompilationCache.noindex, SDKStatCaches.noindex. Pure caches, regenerated
  # on next build. Catches DerivedData-shaped trees with non-standard names.
  "\.noindex(/|$)"

  # Java compiled bytecode — always regenerated from .java source
  "\.class$"

  # Python tool caches and packaging metadata
  "/\.pytest_cache(/|$)"
  "/\.mypy_cache(/|$)"
  "\.egg-info(/|$)"
  "/\.tox(/|$)"
  "/\.nox(/|$)"

  # CocoaPods dependencies — regenerated by pod install
  "/Pods(/|$)"

  # CocoaPods global cache — auto-downloaded on demand by pod install
  "/Library/Caches/CocoaPods/"

  # Vim swap files — ephemeral editor state
  "\.swp$"
  "\.swo$"

  # Ruby Bundler — regenerated by bundle install
  "/vendor/bundle/"

  # Autoconf/configure artifacts — created and deleted thousands of times per
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

  # Examples (uncomment to enable):
  # "\.o$"                                     # C/C++ object files (short extension, opt-in)
  # "\.dSYM(/|$)"                              # Debug symbols (may be needed for crash symbolication)
  # "/target(/|$)"                             # Cargo/Maven build output (common name, opt-in)
)


# TRASH RETENTION
# ----------------
# How many days to keep trashed items before the cleanup scheduler permanently
# deletes them. The scheduler runs every 6 hours; items older than this
# threshold are purged on the next run.
#
# 30 days is the default — long enough to catch most accidental deletions,
# short enough to avoid unbounded disk growth. Raise it if you want a longer
# safety window; lower it (e.g. 7) if disk space is a concern.
#
RETENTION_DAYS=30


# TRASH SIZE CAP
# ---------------
# Hard ceiling on total ai-trash disk usage, in whole gibibytes (GiB). Runs
# AFTER the age-based purge above, as a secondary safety net for the case
# where a lot is trashed within the retention window. When the cap is
# exceeded, the OLDEST items are evicted first until usage drops under it.
#
# Values:
#   (unset / empty)  : auto. 5% of the disk hosting $HOME, capped at 50 GiB.
#                      Scales sensibly across machines (about 13 GiB on a
#                      256 GB drive, 50 GiB on anything 1 TB or larger).
#   0                : disabled. Only RETENTION_DAYS controls trash size.
#   N (integer GiB)  : fixed cap of N GiB.
#
# The cap is enforced once per scheduler run, not on every delete, so a
# burst can briefly exceed it; the next run will bring it back under.
#
# MAX_TRASH_SIZE_GB=
# MAX_TRASH_SIZE_GB=0
# MAX_TRASH_SIZE_GB=20


# SIZE-EVICTION GRACE PERIOD
# ---------------------------
# When the size cap above is exceeded, items are evicted oldest-first.
# This setting exempts very recent items: anything trashed within the last
# N hours stays put, even if the cap is over. It exists because a single
# huge AI-deleted item shouldn't be permanently removed before you've had
# a chance to notice and restore it.
#
# Effect: the cap is a soft cap during the grace window. If your trash is
# 200 GiB and your cap is 50 GiB but everything was trashed in the last
# 24 hours, nothing is evicted by the size cap. RETENTION_DAYS still bounds
# long-term trash size.
#
# Set to 0 to disable the grace period (revert to strict oldest-first
# eviction regardless of recency).
#
SIZE_EVICTION_GRACE_HOURS=24


# ADDING YOUR OWN TOOLS
# ----------------------
# If an AI tool you use isn't listed above, add it to the appropriate section:
#
#   • It sets a terminal env var?  → add to AI_ENV_VARS
#   • It runs as its own binary?   → add to AI_PROCESSES
#   • It runs inside node/python?  → add to AI_PROCESS_ARGS
#
# To identify a tool's process name, run it then check:
#   ps aux | grep -i <toolname>
#
# To find its terminal env var (if IDE-integrated):
#   Open a terminal inside the tool and run:  env | grep -i term
