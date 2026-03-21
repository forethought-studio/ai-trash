#!/bin/bash
# uninstall.sh — remove ai-trash on macOS or Linux
set -euo pipefail

PLATFORM=$(uname -s)

# Match the same BIN detection as install.sh
if [[ "$PLATFORM" == "Darwin" ]]; then
  if [[ -d /opt/homebrew/bin ]]; then
    BIN=/opt/homebrew/bin
  else
    BIN=/usr/local/bin
  fi
else
  BIN=/usr/local/bin
fi

echo "Uninstalling ai-trash..."

# ─── Cleanup scheduler ─────────────────────────────────────────────────

if [[ "$PLATFORM" == "Darwin" ]]; then
  AGENT_DIR="$HOME/Library/LaunchAgents"
  AGENT_LABEL="com.ai-trash.cleanup"
  AGENT_PLIST="$AGENT_DIR/${AGENT_LABEL}.plist"

  if [[ -f "$AGENT_PLIST" ]]; then
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || \
    launchctl unload "$AGENT_PLIST" 2>/dev/null || true
    rm -f "$AGENT_PLIST"
    echo "  LaunchAgent removed"
  fi

else
  # Linux: remove the cron job
  CRON_MARKER="# ai-trash-cleanup"
  if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
    crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" | crontab -
    echo "  cron job removed"
  fi
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

if [[ "$PLATFORM" == "Darwin" ]]; then
  TRASH_DIR="~/.Trash/ai-trash"
else
  TRASH_DIR="~/.local/share/Trash/ai-trash"
fi

echo ""
echo "Uninstalled. Your AI trash contents are still in $TRASH_DIR/"
echo "To remove them permanently: /bin/rm -rf $TRASH_DIR"
