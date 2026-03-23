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
