#!/bin/bash
# install.sh — install ai-trash on macOS
set -euo pipefail

# Detect install prefix: Apple Silicon Homebrew uses /opt/homebrew, Intel uses /usr/local
if [[ -d /opt/homebrew/bin ]]; then
  BIN=/opt/homebrew/bin
else
  BIN=/usr/local/bin
fi
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT_LABEL="com.ai-trash.cleanup"
AGENT_PLIST="$AGENT_DIR/${AGENT_LABEL}.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Preflight ─────────────────────────────────────────────────────────

if [[ "$(uname)" != "Darwin" ]]; then
  echo "error: ai-trash requires macOS" >&2
  exit 1
fi

# Check that $BIN comes before /bin in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN"; then
  echo "warning: $BIN is not in your PATH — the rm override won't take effect."
  echo "         Add this to your shell config and re-run:"
  echo "         export PATH=\"$BIN:\$PATH\""
else
  path_our=$(echo "$PATH" | tr ':' '\n' | grep -nx "$BIN"  | head -1 | cut -d: -f1)
  path_bin=$(echo "$PATH" | tr ':' '\n' | grep -nx "/bin$" | head -1 | cut -d: -f1)
  if [[ -n "$path_our" && -n "$path_bin" && "$path_our" -gt "$path_bin" ]]; then
    echo "warning: /bin appears before $BIN in your PATH."
    echo "         The rm override won't intercept calls until this is fixed."
  fi
fi

# ─── Install binaries ──────────────────────────────────────────────────

echo "Installing to $BIN (may prompt for sudo)..."

# Back up existing /usr/local/bin/rm if it isn't already our wrapper
if [[ -f "$BIN/rm" && ! -L "$BIN/rm" ]]; then
  sudo cp "$BIN/rm" "$BIN/rm_wrapper_old.sh"
  echo "  backed up existing $BIN/rm → $BIN/rm_wrapper_old.sh"
fi

sudo cp "$SCRIPT_DIR/rm_wrapper.sh"    "$BIN/rm_wrapper.sh"
sudo cp "$SCRIPT_DIR/ai-trash-cleanup" "$BIN/ai-trash-cleanup"
sudo cp "$SCRIPT_DIR/ai-trash"         "$BIN/ai-trash"

sudo chmod 755 "$BIN/rm_wrapper.sh" "$BIN/ai-trash-cleanup" "$BIN/ai-trash"

# Create rm and rmdir symlinks
sudo ln -sf "$BIN/rm_wrapper.sh" "$BIN/rm"
sudo ln -sf "$BIN/rm_wrapper.sh" "$BIN/rmdir"

echo "  rm_wrapper.sh installed"
echo "  $BIN/rm  → rm_wrapper.sh"
echo "  $BIN/rmdir → rm_wrapper.sh"
echo "  ai-trash-cleanup installed"
echo "  ai-trash installed"

# ─── Config ────────────────────────────────────────────────────────────

CONFIG_DIR="$HOME/.config/ai-trash"
CONFIG_FILE="$CONFIG_DIR/config.sh"

mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_FILE" ]]; then
  cp "$SCRIPT_DIR/config.default.sh" "$CONFIG_FILE"
  echo "  config installed → $CONFIG_FILE"
  echo "  (edit this file to customise which AI tools are protected)"
else
  echo "  config already exists, skipping → $CONFIG_FILE"
fi

# ─── LaunchAgent ───────────────────────────────────────────────────────

mkdir -p "$AGENT_DIR"
cp "$SCRIPT_DIR/com.ai-trash.cleanup.plist" "$AGENT_PLIST"

# Unload first in case of re-install
launchctl unload "$AGENT_PLIST" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true

if launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null ||
   launchctl load "$AGENT_PLIST" 2>/dev/null; then
  echo "  LaunchAgent loaded (runs every 6 hours, purges items >30 days old)"
else
  echo "  LaunchAgent installed but not loaded (will activate on next login)"
fi

# ─── Done ──────────────────────────────────────────────────────────────

echo ""
echo "Done. Your rm is now protected."
echo ""
echo "  rm myfile.txt          → moves to ~/.Trash/ai-trash/ (recoverable)"
echo "  ai-trash list          → show everything in AI trash"
echo "  ai-trash restore <name> → restore to original location"
echo "  ai-trash empty         → permanently delete all AI trash"
