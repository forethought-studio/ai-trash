# ai-trash configuration (PowerShell)
# Installed to: $env:USERPROFILE\.config\ai-trash\config.ps1
# ---------------------------------------------------------------------------
# This file is dot-sourced. Changes take effect the next time a new shell
# session starts (or when rm_wrapper.ps1 is re-dot-sourced).
# Lines starting with # are comments and have no effect.
# ---------------------------------------------------------------------------


# PROTECTION MODE
# ---------------
# Controls which Remove-Item calls ai-trash intercepts.
#
#   selective  (default) — only intercept Remove-Item when an AI tool is
#                          detected anywhere in the process call chain. Your
#                          own Remove-Item commands pass straight through to
#                          the built-in cmdlet unchanged, exactly as if
#                          ai-trash were not installed.
#                          Best for: developers who trust their own deletions
#                          and only want protection from AI tools.
#
#   safe                 — AI calls go to ai-trash (with full metadata).
#                          Non-AI calls move items to the Windows Recycle Bin
#                          via Shell.Application instead of permanently
#                          deleting them. Nothing typed at a terminal ever
#                          vanishes silently. Items from non-AI deletions
#                          won't appear in `ai-trash list` but are
#                          recoverable via the Recycle Bin.
#                          Best for: anyone who wants a complete safety net
#                          without polluting ai-trash with their own deletions.
#
$MODE = 'selective'
# $MODE = 'safe'


# AI ENVIRONMENT VARIABLES  (selective mode only)
# ------------------------------------------------
# Checked before any process lookup — zero performance overhead.
# Format: "VAR_NAME=value"  (exact match on the value)
#
# IDE-integrated terminals set TERM_PROGRAM to identify themselves. If your
# AI tool's terminal isn't listed, add it here. To find the right value, open
# a terminal inside your tool and run:  $env:TERM_PROGRAM
#
$AI_ENV_VARS = @(
    'TERM_PROGRAM=cursor',       # Cursor IDE
    'TERM_PROGRAM=vscode',       # VS Code — covers GitHub Copilot, Cline,
                                 #   Continue.dev, Roo, and other VS Code extensions
    'TERM_PROGRAM=windsurf',     # Windsurf (formerly Codeium)
    'TERM_PROGRAM=WarpTerminal'  # Warp terminal — covers the built-in Oz agent
                                 #   and any CLI agent run inside Warp
)


# AI PROCESS NAMES  (selective mode only)
# ----------------------------------------
# Matched against the executable name (without extension) at every level of
# the process tree, walking all the way up to PID 0/1.
#
# Use this for tools that ship as their own named binary.
# To find the right name, run the tool then check:
#   Get-CimInstance Win32_Process | Where-Object { $_.Name -like "*<toolname>*" }
#
$AI_PROCESSES = @(
    'claude',     # Claude Code (Anthropic)
    'gemini',     # Gemini CLI (Google) — standalone binary install
    'goose',      # Goose (Block/Square)
    'opencode',   # OpenCode — open-source Claude Code alternative
    'aider',      # Aider — when installed as a standalone script
    'devin',      # Devin (Cognition)
    'kiro-cli'    # Kiro CLI (AWS) — formerly Amazon Q Developer CLI
)


# AI PROCESS ARGS  (selective mode only)
# ----------------------------------------
# Substring-matched against the full command line at every level of the
# process tree. Use this for tools that run inside node, python, etc., where
# the process name alone is just "node" or "python" and isn't enough.
#
# Each entry is a plain substring — no glob or regex. Keep patterns specific
# enough to avoid matching unrelated processes (e.g. "aider" is fine;
# "ai" would be too broad).
#
$AI_PROCESS_ARGS = @(
    'codex',       # OpenAI Codex CLI      (runs as: node ...\codex\...)
    'aider',       # Aider                 (runs as: python ...\aider\... — belt+suspenders
                   #                        with the AI_PROCESSES entry above)
    'gemini-cli',  # Gemini CLI via npx    (runs as: node ...@google\gemini-cli\...)
    'gh copilot',  # GitHub Copilot CLI    (runs as: node ...\gh-copilot\...)
    'openhands',   # OpenHands             (runs as: python ...\openhands\...)
    'opencode'     # OpenCode              (belt+suspenders with AI_PROCESSES above)
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
$RETENTION_DAYS = 30


# ADDING YOUR OWN TOOLS
# ----------------------
# If an AI tool you use isn't listed above, add it to the appropriate array:
#
#   - It sets a terminal env var?  -> add to $AI_ENV_VARS
#   - It runs as its own binary?   -> add to $AI_PROCESSES
#   - It runs inside node/python?  -> add to $AI_PROCESS_ARGS
#
# To identify a tool's process name, run it then check:
#   Get-CimInstance Win32_Process | Select-Object Name, CommandLine | Where-Object { $_.Name -like "*node*" }
#
# To find its terminal env var (if IDE-integrated):
#   Open a terminal inside the tool and run:  Get-ChildItem Env: | Where-Object { $_.Name -like "*TERM*" }
