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
  # macOS candidates — PATH ordering decides which wins
  CANDIDATES=(/opt/homebrew/bin /usr/local/bin)
else
  CANDIDATES=(/usr/local/bin)
fi

# Walk PATH to find which candidate appears first
BIN=""
while IFS= read -r dir; do
  for c in "${CANDIDATES[@]}"; do
    if [[ "$dir" == "$c" && -d "$c" ]]; then
      BIN="$c"
      break 2
    fi
  done
done < <(echo "$PATH" | tr ':' '\n')

# Fallback if no candidate is in PATH
if [[ -z "$BIN" ]]; then
  if [[ -d /opt/homebrew/bin ]]; then
    BIN=/opt/homebrew/bin
  else
    BIN=/usr/local/bin
  fi
  echo "warning: neither /opt/homebrew/bin nor /usr/local/bin found in PATH."
  echo "         Installing to $BIN — add it to your PATH for rm to work."
fi

# ─── Preflight ─────────────────────────────────────────────────────────

# Check that $BIN comes before /bin in PATH
path_our=$(echo "$PATH" | tr ':' '\n' | grep -nx "$BIN"  | head -1 | cut -d: -f1)
path_bin=$(echo "$PATH" | tr ':' '\n' | grep -nx "/bin$" | head -1 | cut -d: -f1)
if [[ -n "$path_our" && -n "$path_bin" && "$path_our" -gt "$path_bin" ]]; then
  echo "warning: /bin appears before $BIN in your PATH."
  echo "         The rm override won't intercept calls until this is fixed."
fi

# ─── Install binaries ──────────────────────────────────────────────────

echo "Installing to $BIN (may prompt for sudo)..."

# Back up existing rm if it isn't already our wrapper
if [[ -f "$BIN/rm" && ! -L "$BIN/rm" ]]; then
  sudo cp "$BIN/rm" "$BIN/rm_wrapper_old.sh"
  echo "  backed up existing $BIN/rm → $BIN/rm_wrapper_old.sh"
fi

sudo cp "$SCRIPT_DIR/ai-trash-lib.sh"   "$BIN/ai-trash-lib.sh"
sudo cp "$SCRIPT_DIR/rm_wrapper.sh"    "$BIN/rm_wrapper.sh"
sudo cp "$SCRIPT_DIR/git_wrapper.sh"   "$BIN/git_wrapper.sh"
sudo cp "$SCRIPT_DIR/find_wrapper.sh"  "$BIN/find_wrapper.sh"
sudo cp "$SCRIPT_DIR/rsync_wrapper.sh" "$BIN/rsync_wrapper.sh"
sudo cp "$SCRIPT_DIR/ai-trash-cleanup" "$BIN/ai-trash-cleanup"
sudo cp "$SCRIPT_DIR/ai-trash"         "$BIN/ai-trash"
sudo cp "$SCRIPT_DIR/scripts/check-path-shadows.sh" "$BIN/check-path-shadows.sh"

sudo chmod 755 "$BIN/ai-trash-lib.sh" "$BIN/rm_wrapper.sh" "$BIN/git_wrapper.sh" \
  "$BIN/find_wrapper.sh" "$BIN/rsync_wrapper.sh" "$BIN/ai-trash-cleanup" "$BIN/ai-trash" \
  "$BIN/check-path-shadows.sh"

# Create rm, rmdir, and unlink symlinks
sudo ln -sf "$BIN/rm_wrapper.sh" "$BIN/rm"
sudo ln -sf "$BIN/rm_wrapper.sh" "$BIN/rmdir"
sudo ln -sf "$BIN/rm_wrapper.sh" "$BIN/unlink"

# Create git, find, and rsync symlinks
sudo ln -sf "$BIN/git_wrapper.sh" "$BIN/git"
sudo ln -sf "$BIN/find_wrapper.sh" "$BIN/find"
sudo ln -sf "$BIN/rsync_wrapper.sh" "$BIN/rsync"

echo "  ai-trash-lib.sh installed (shared library)"
echo "  rm_wrapper.sh installed"
echo "  $BIN/rm     → rm_wrapper.sh"
echo "  $BIN/rmdir  → rm_wrapper.sh"
echo "  $BIN/unlink → rm_wrapper.sh"
echo "  git_wrapper.sh installed"
echo "  $BIN/git    → git_wrapper.sh"
echo "  find_wrapper.sh installed"
echo "  $BIN/find   → find_wrapper.sh"
echo "  rsync_wrapper.sh installed"
echo "  $BIN/rsync  → rsync_wrapper.sh"
echo "  ai-trash-cleanup installed"
echo "  ai-trash installed"
echo "  check-path-shadows.sh installed (duplicate-wrapper scanner)"

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

# ─── PATH-shadow scanner (daily) + sticky banner ───────────────────────
# Detects duplicate command wrappers on PATH that could re-introduce the
# wrapper-recursion spin. Auto-quarantines stale ai-trash copies; surfaces
# anything it can't safely fix via a banner printed by every new shell.
sudo cp "$SCRIPT_DIR/scripts/ai-trash-banner.sh" "$BIN/ai-trash-banner.sh"
sudo chmod 644 "$BIN/ai-trash-banner.sh"

if [[ "$PLATFORM" == "Darwin" ]]; then
  SCAN_LABEL="com.ai-trash.path-shadow-scan"
  SCAN_PLIST="$HOME/Library/LaunchAgents/${SCAN_LABEL}.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  # Point the plist at the actual install dir (the template assumes /usr/local/bin).
  sed "s#/usr/local/bin/check-path-shadows.sh#$BIN/check-path-shadows.sh#" \
    "$SCRIPT_DIR/com.ai-trash.path-shadow-scan.plist" > "$SCAN_PLIST"
  launchctl unload "$SCAN_PLIST" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/$SCAN_LABEL" 2>/dev/null || true
  if launchctl bootstrap "gui/$(id -u)" "$SCAN_PLIST" 2>/dev/null ||
     launchctl load "$SCAN_PLIST" 2>/dev/null; then
    echo "  PATH-shadow scan LaunchAgent loaded (runs daily)"
  else
    echo "  PATH-shadow scan LaunchAgent installed but not loaded (activates on next login)"
  fi
else
  SCAN_CRON_MARKER="# ai-trash-path-shadow-scan"
  SCAN_CRON_LINE="30 9 * * * $BIN/check-path-shadows.sh $SCAN_CRON_MARKER"
  if crontab -l 2>/dev/null | grep -qF "$SCAN_CRON_MARKER"; then
    echo "  PATH-shadow scan cron already installed (runs daily)"
  else
    ( crontab -l 2>/dev/null; echo "$SCAN_CRON_LINE" ) | crontab -
    echo "  PATH-shadow scan cron installed (runs daily)"
  fi
fi

# Wire the sticky banner into the user's shell rc (idempotent, clearly fenced).
_AIT_BANNER_BEGIN="# >>> ai-trash banner >>>"
_AIT_BANNER_END="# <<< ai-trash banner <<<"
for _rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  [[ -e "$_rc" ]] || continue
  if grep -qF "$_AIT_BANNER_BEGIN" "$_rc" 2>/dev/null; then
    continue   # already wired
  fi
  {
    printf '%s\n' "$_AIT_BANNER_BEGIN"
    printf '%s\n' "[ -f \"$BIN/ai-trash-banner.sh\" ] && . \"$BIN/ai-trash-banner.sh\""
    printf '%s\n' "$_AIT_BANNER_END"
  } >> "$_rc"
  echo "  banner hook added to $_rc"
done

# ─── Done ──────────────────────────────────────────────────────────────

if [[ "$PLATFORM" == "Darwin" ]]; then
  TRASH_EXAMPLE="~/.Trash/ai-trash/"
else
  TRASH_EXAMPLE="~/.local/share/Trash/ai-trash/"
fi

echo ""
echo "Done. AI-triggered deletions are now protected."
echo ""
echo "  rm myfile.txt           → moves to $TRASH_EXAMPLE (recoverable)"
echo "  git clean -fd           → snapshots files before cleaning"
echo "  git reset --hard        → snapshots changes before resetting"
echo "  rsync -a --delete       → backs up replaced/deleted destination files"
echo "  ai-trash list           → show everything in AI trash"
echo "  ai-trash restore <name> → restore to original location"
echo "  ai-trash empty          → permanently delete all AI trash"

# ─── Stale install cleanup ─────────────────────────────────────────────
# Remove any ai-trash wrappers left in other candidate directories.
for c in "${CANDIDATES[@]}"; do
  [[ "$c" == "$BIN" ]] && continue
  if [[ -f "$c/rm_wrapper.sh" ]] && grep -q "ai-trash" "$c/rm_wrapper.sh" 2>/dev/null; then
    echo "  removing stale install from $c"
    for f in ai-trash-lib.sh rm_wrapper.sh git_wrapper.sh find_wrapper.sh rsync_wrapper.sh ai-trash ai-trash-cleanup check-path-shadows.sh ai-trash-banner.sh; do
      sudo rm -f "$c/$f"
    done
    for cmd in rm rmdir unlink git find rsync; do
      target=$(readlink "$c/$cmd" 2>/dev/null || true)
      if [[ "$target" == *_wrapper* ]]; then
        sudo rm -f "$c/$cmd"
      fi
    done
  fi
done
