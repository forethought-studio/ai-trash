#!/bin/bash
# uninstall.sh — remove ai-trash from macOS
set -euo pipefail

BIN=/usr/local/bin
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT_LABEL="com.ai-trash.cleanup"
AGENT_PLIST="$AGENT_DIR/${AGENT_LABEL}.plist"

echo "Uninstalling ai-trash..."

# ─── Unload LaunchAgent ────────────────────────────────────────────────

if [[ -f "$AGENT_PLIST" ]]; then
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || \
  launchctl unload "$AGENT_PLIST" 2>/dev/null || true
  rm -f "$AGENT_PLIST"
  echo "  LaunchAgent removed"
fi

# ─── Remove symlinks (only if they point to our wrapper) ───────────────

for cmd in rm rmdir; do
  target=$(readlink "$BIN/$cmd" 2>/dev/null || true)
  if [[ "$target" == "$BIN/rm_wrapper.sh" || "$target" == *rm_wrapper* ]]; then
    sudo rm -f "$BIN/$cmd"
    echo "  removed $BIN/$cmd"
  fi
done

# ─── Remove scripts ────────────────────────────────────────────────────

for f in rm_wrapper.sh ai-trash-cleanup ai-trash; do
  if [[ -f "$BIN/$f" ]]; then
    sudo rm -f "$BIN/$f"
    echo "  removed $BIN/$f"
  fi
done

# Restore backed-up wrapper if present
if [[ -f "$BIN/rm_wrapper_old.sh" ]]; then
  sudo mv "$BIN/rm_wrapper_old.sh" "$BIN/rm"
  echo "  restored previous $BIN/rm"
fi

# ─── Done ──────────────────────────────────────────────────────────────

echo ""
echo "Uninstalled. Your AI trash contents are still in ~/.Trash/ai-trash/"
echo "To remove them permanently: /bin/rm -rf ~/.Trash/ai-trash"
