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


# AI DETECTION  (selective mode only)
# ------------------------------------------------
# Three lists decide whether the caller of an rm/git/find/rsync is an AI tool:
#
#   AI_ENV_VARS      "VAR=value" pairs, checked before any process lookup
#   AI_PROCESSES     executable names, matched at every level of the tree
#   AI_PROCESS_ARGS  command-line substrings, for tools running inside
#                    node/python where the process name is just "node"
#
# ai-trash SHIPS all three. They live in ai-trash-lib.sh, which every upgrade
# replaces, NOT in this file, which the installer refuses to overwrite once you
# have one. That placement is load-bearing rather than tidy: while the shipped
# lists lived here, a config file kept its own frozen copy forever, so a machine
# installed before "CLAUDECODE=1" was added stopped recognising Claude Code and
# silently deleted its files for real. Run `ai-trash detection` to see the live
# lists.
#
# The three arrays below are YOUR ADDITIONS, merged on top of the shipped ones.
# Leave them empty unless you have a tool ai-trash does not already know.


# ADD AN AI TOOL BY ENVIRONMENT VARIABLE
# ---------------------------------------
# Format: "VAR_NAME=value" (exact match on the value). Cheapest signal there
# is: it costs no process lookup. IDE terminals set TERM_PROGRAM to identify
# themselves; open a terminal inside your tool and run:  echo $TERM_PROGRAM
#
AI_ENV_VARS=(
  # "TERM_PROGRAM=myeditor"
  # "MYTOOL_SESSION=1"
)


# ADD AN AI TOOL BY PROCESS NAME
# -------------------------------
# Matched against the executable name (basename) at every level of the process
# tree, up to launchd (PID 1). For tools that ship as their own named binary.
# To find the right name, run the tool and check:  ps aux | grep <toolname>
#
AI_PROCESSES=(
  # mytool
)


# ADD AN AI TOOL BY COMMAND LINE
# -------------------------------
# Plain substring (no glob, no regex) matched against the full command line at
# every level of the tree. For tools that run inside node, python, etc., where
# the process name alone is just "node" or "python3".
#
# Keep entries specific enough not to catch unrelated processes: "aider" is
# fine, "ai" would match half the process table.
#
AI_PROCESS_ARGS=(
  # "mytool-cli"
)


# TURNING A SHIPPED DETECTION ENTRY OFF
# --------------------------------------
# Exact strings from the shipped lists that you do NOT want matched, across all
# three. Copy them verbatim from `ai-trash detection`.
#
# The generic names are what this is for. ai-trash ships "q" because that was
# Amazon Q Developer CLI's binary name, so if you have your own `q` on PATH,
# every delete it makes is treated as an AI delete. That is a safe direction to
# be wrong in (you get a recoverable copy), but it is not always what you want:
#
#   DISABLE_BUILTIN_AI_DETECTION=(
#     "q"
#   )
#
DISABLE_BUILTIN_AI_DETECTION=()


# TURNING ALL SHIPPED DETECTION OFF
# ----------------------------------
# Master switch. Leave true to detect the tools ai-trash knows about plus your
# additions. Set to false to detect ONLY what you listed above.
#
# Note this is the mirror image of USE_BUILTIN_BYPASS_PATTERNS, which requires
# the exact string "true". Here anything other than "false" counts as true,
# because detecting a tool ADDS protection while bypassing a path permanently
# deletes: a value ai-trash cannot read should leave the protective default on
# and the destructive one off. Both rules keep your file.
#
USE_BUILTIN_AI_DETECTION=true
# USE_BUILTIN_AI_DETECTION=false


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
# Files whose resolved absolute path matches a bypass pattern are permanently
# deleted (/bin/rm) instead of going to ai-trash. That is for paths with zero
# recovery value, so tool churn does not bloat the trash the way it did on a
# profiled host where one AI tool's ephemeral snapshots were 90.4% of every
# item trashed in a retention window.
#
# ai-trash SHIPS a builtin list of such patterns (git lock files, node_modules,
# DerivedData, __pycache__, AI-tool scratch state, and about eighty more). The
# builtins do NOT live in this file, and that is deliberate: the installer never
# overwrites a config you already have, so any default shipped here would reach
# new installs only and freeze forever on every machine that upgraded. They live
# in ai-trash-lib.sh, which every upgrade DOES replace, so new shipped defaults
# reach you automatically. See `ai-trash bypass-patterns` for the live list.
#
# The three knobs below are yours; the builtin list is not meant to be edited.
#
# Patterns are extended regular expressions (ERE), matched with bash =~.
# $HOME is expanded at config-load time when written inside double quotes.
# A pattern without ^ or $ anchors matches anywhere in the path.
#
# Effective list = builtins (unless disabled) - DISABLE_... + BYPASS_...


# YOUR ADDITIONS
# ---------------
# Extra patterns to bypass, on top of the builtins. `ai-trash suggest` analyses
# what is actually in your trash and prints ready-to-paste entries for here.
#
# Use += rather than = if you want to be sure you are adding to, and not
# replacing, anything set earlier in this file.
#
BYPASS_TRASH_PATTERNS=(
  # Examples (uncomment to enable):
  # "\.o$"                                     # C/C++ object files (short extension, opt-in)
  # "\.dSYM(/|$)"                              # Debug symbols (may be needed for crash symbolication)
  # "/target(/|$)"                              # Cargo/Maven build output (common name, opt-in)
)


# TURNING A SHIPPED DEFAULT OFF
# ------------------------------
# Exact pattern strings from the builtin list that you do NOT want applied.
# The match is an exact string comparison, not a regex: copy the string
# verbatim from `ai-trash bypass-patterns`, which prints the live builtin list
# and warns about entries here that match no builtin (a typo would otherwise
# fail silently).
#
# Example - keep node_modules and .DS_Store recoverable:
#   DISABLE_BUILTIN_BYPASS_PATTERNS=(
#     "/node_modules/"
#     "\.DS_Store$"
#   )
#
DISABLE_BUILTIN_BYPASS_PATTERNS=()


# TURNING ALL SHIPPED DEFAULTS OFF
# ---------------------------------
# Master switch. Leave true to get the shipped list plus your additions. Set to
# false to ignore the builtin list entirely, so ONLY BYPASS_TRASH_PATTERNS above
# decides what skips the trash - including the empty case, where nothing is ever
# permanently deleted and every intercepted delete is recoverable.
#
# Only the exact string "true" enables the builtins, the same rule the
# GIT_PROTECTION / FIND_PROTECTION / RSYNC_PROTECTION toggles follow. A typo
# ("TRUE", "yes") therefore leaves them off rather than on: a bypass PERMANENTLY
# deletes, so a value ai-trash cannot read must not authorise that. Deleting the
# line entirely is also fine and means true. `ai-trash bypass-patterns` tells you
# which of the three cases you are in.
#
USE_BUILTIN_BYPASS_PATTERNS=true
# USE_BUILTIN_BYPASS_PATTERNS=false


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


# TRASH ITEM-COUNT CAP
# ---------------------
# Hard ceiling on the NUMBER of ai-trash entries in the trash directory.
# Like the size cap it runs after the age-based purge, evicting the OLDEST
# items first until the count drops under it.
#
# Why this exists as its own axis, and why the size cap does not cover it:
# the cost that actually degrades a machine is per-ENTRY, not per-byte.
# Finder continuously re-enumerates ~/.Trash to maintain its size and its
# Dock badge, issuing one getattrlist per entry, so a trash holding many
# tiny files is far more expensive than one holding a few large ones. On a
# measured agent-driven host, 73,121 top-level entries averaging ~167 KB
# each held Finder at 99-100% of a CPU core continuously, surviving every
# Finder relaunch, because the driver was the directory rather than process
# state. A 10 GiB size cap would still have permitted ~60,000 of them, and
# an age cap bounds only count x intake rate -- and intake rate on a machine
# running AI agents all day is orders of magnitude above the human case the
# 30-day retention default was chosen for.
#
# Values:
#   (unset / empty)  : auto. 25,000 items. Roughly a third of the count
#                      measured to pin Finder to a core, and well above the
#                      steady state of the busiest profiled agent host
#                      (~16,500: about 550 genuine deletions a day held for
#                      30 days), so it behaves as a safety net for an
#                      unprofiled workload rather than as a silent
#                      shortening of RETENTION_DAYS.
#   0                : disabled. Only RETENTION_DAYS and MAX_TRASH_SIZE_GB
#                      bound the trash.
#   N (integer)      : fixed cap of N items.
#
# The cap counts only ai-trash's own entries -- items you or another app put
# in the trash are never evicted by it, and are not counted towards it.
# Like the size cap it is enforced once per scheduler run, not on every
# delete, so a burst can briefly exceed it.
#
# If you are seeing a runaway item count, raising this is the wrong lever:
# add the offending path family to BYPASS_TRASH_PATTERNS above so the churn
# never reaches the trash in the first place. This cap is the backstop for
# the families nobody has profiled yet.
#
# MAX_TRASH_ITEMS=
# MAX_TRASH_ITEMS=0
# MAX_TRASH_ITEMS=50000


# CAP-EVICTION GRACE PERIOD
# --------------------------
# When either cap above is exceeded, items are evicted oldest-first.
# This setting exempts very recent items: anything trashed within the last
# N hours stays put, even if a cap is over. It exists because a single
# huge AI-deleted item shouldn't be permanently removed before you've had
# a chance to notice and restore it.
#
# Effect: both caps are soft caps during the grace window. If your trash is
# 200 GiB and your cap is 50 GiB but everything was trashed in the last
# 24 hours, nothing is evicted. RETENTION_DAYS still bounds long-term trash
# size and item count.
#
# Set to 0 to disable the grace period (revert to strict oldest-first
# eviction regardless of recency).
#
# The name is historical -- this applied only to the size cap before the
# item cap existed -- and is kept so existing config files keep working.
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
