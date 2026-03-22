#!/bin/bash
# install.sh — install ai-trash on macOS or Linux
set -euo pipefail

# ─── Remote install detection ──────────────────────────────────────────
# When run via: curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash
# $BASH_SOURCE[0] is empty or /dev/stdin — download the repo and re-exec.
_SRC="${BASH_SOURCE[0]:-}"
if [[ -z "$_SRC" || "$_SRC" == "/dev/stdin" ]]; then
  echo "Downloading ai-trash..."
  _TMP=$(mktemp -d)
  trap 'rm -rf "$_TMP"' EXIT
  curl -fsSL https://github.com/forethought-studio/ai-trash/archive/refs/heads/main.tar.gz \
    | tar -xz -C "$_TMP" --strip-components=1
  exec bash "$_TMP/install.sh"
fi

PLATFORM=$(uname -s)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Detect install prefix ─────────────────────────────────────────────

if [[ "$PLATFORM" == "Darwin" ]]; then
  # Apple Silicon Homebrew uses /opt/homebrew, Intel uses /usr/local
  if [[ -d /opt/homebrew/bin ]]; then
    BIN=/opt/homebrew/bin
  else
    BIN=/usr/local/bin
  fi
else
  # Linux: prefer /usr/local/bin (no sudo needed if user owns it, else sudo)
  BIN=/usr/local/bin
fi

# ─── Preflight ─────────────────────────────────────────────────────────

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

# Back up existing rm if it isn't already our wrapper
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

# ─── Cleanup scheduler ─────────────────────────────────────────────────

if [[ "$PLATFORM" == "Darwin" ]]; then
  AGENT_DIR="$HOME/Library/LaunchAgents"
  AGENT_LABEL="com.ai-trash.cleanup"
  AGENT_PLIST="$AGENT_DIR/${AGENT_LABEL}.plist"

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

else
  # Linux: install a cron job for the current user (runs every 6 hours)
  CRON_MARKER="# ai-trash-cleanup"
  CRON_LINE="0 */6 * * * $BIN/ai-trash-cleanup $CRON_MARKER"

  # Only add if not already present
  if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
    echo "  cron job already installed (runs every 6 hours, purges items >30 days old)"
  else
    ( crontab -l 2>/dev/null; echo "$CRON_LINE" ) | crontab -
    echo "  cron job installed (runs every 6 hours, purges items >30 days old)"
  fi
fi

# ─── Done ──────────────────────────────────────────────────────────────

if [[ "$PLATFORM" == "Darwin" ]]; then
  TRASH_EXAMPLE="~/.Trash/ai-trash/"
else
  TRASH_EXAMPLE="~/.local/share/Trash/ai-trash/"
fi

echo ""
echo "Done. Your rm is now protected."
echo ""
echo "  rm myfile.txt           → moves to $TRASH_EXAMPLE (recoverable)"
echo "  ai-trash list           → show everything in AI trash"
echo "  ai-trash restore <name> → restore to original location"
echo "  ai-trash empty          → permanently delete all AI trash"

# ─── Post-install verification ─────────────────────────────────────────
# Confirm that `rm` in the current PATH resolves to our newly installed wrapper.
# On Apple Silicon Macs that have both /usr/local/bin and /opt/homebrew/bin in PATH,
# an old rm at the earlier directory silently shadows the install. Fix it automatically.
actual_rm=$(which rm 2>/dev/null || true)
if [[ "$actual_rm" != "$BIN/rm" && -n "$actual_rm" ]]; then
  shadow_dir=$(dirname "$actual_rm")
  echo "  fixing shadow: $actual_rm also points to an old wrapper — updating it"
  sudo cp "$BIN/rm_wrapper.sh" "$shadow_dir/rm_wrapper.sh"
  sudo chmod 755 "$shadow_dir/rm_wrapper.sh"
  sudo ln -sf "$shadow_dir/rm_wrapper.sh" "$shadow_dir/rm"
  sudo ln -sf "$shadow_dir/rm_wrapper.sh" "$shadow_dir/rmdir"
  echo "  $shadow_dir/rm → rm_wrapper.sh (updated)"
fi
