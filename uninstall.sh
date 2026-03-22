#!/bin/bash
# uninstall.sh — remove ai-trash on macOS or Linux
set -euo pipefail

PLATFORM=$(uname -s)

# Match the same BIN detection as install.sh
if [[ "$PLATFORM" == "Darwin" ]]; then
  CANDIDATES=(/opt/homebrew/bin /usr/local/bin)
else
  CANDIDATES=(/usr/local/bin)
fi

BIN=""
while IFS= read -r dir; do
  for c in "${CANDIDATES[@]}"; do
    if [[ "$dir" == "$c" && -d "$c" ]]; then
      BIN="$c"
      break 2
    fi
  done
done < <(echo "$PATH" | tr ':' '\n')

if [[ -z "$BIN" ]]; then
  if [[ -d /opt/homebrew/bin ]]; then
    BIN=/opt/homebrew/bin
  else
    BIN=/usr/local/bin
  fi
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

# Clean up stale ai-trash installs from other candidate directories
for c in "${CANDIDATES[@]}"; do
  [[ "$c" == "$BIN" ]] && continue
  if [[ -f "$c/rm_wrapper.sh" ]] && grep -q "ai-trash" "$c/rm_wrapper.sh" 2>/dev/null; then
    echo "  removing stale install from $c"
    for f in rm_wrapper.sh ai-trash ai-trash-cleanup; do
      sudo rm -f "$c/$f"
    done
    for cmd in rm rmdir; do
      target=$(readlink "$c/$cmd" 2>/dev/null || true)
      if [[ "$target" == *rm_wrapper* ]]; then
        sudo rm -f "$c/$cmd"
      fi
    done
  fi
done

# ─── Done ──────────────────────────────────────────────────────────────

if [[ "$PLATFORM" == "Darwin" ]]; then
  TRASH_DIR="~/.Trash/ai-trash"
else
  TRASH_DIR="~/.local/share/Trash/ai-trash"
fi

echo ""
echo "Uninstalled. Your AI trash contents are still in $TRASH_DIR/"
echo "To remove them permanently: /bin/rm -rf $TRASH_DIR"
