# ai-trash

[![Test macOS / Linux](https://github.com/forethought-studio/ai-trash/actions/workflows/test-macos.yml/badge.svg)](https://github.com/forethought-studio/ai-trash/actions/workflows/test-macos.yml)
[![Test Windows PowerShell](https://github.com/forethought-studio/ai-trash/actions/workflows/test-windows.yml/badge.svg)](https://github.com/forethought-studio/ai-trash/actions/workflows/test-windows.yml)

A transparent `rm`/`Remove-Item` replacement for macOS, Linux, and Windows that routes deleted files to a recoverable trash folder instead of destroying them permanently — designed specifically for environments where AI coding assistants (Claude Code, Codex, Cursor, Copilot, etc.) delete files on your behalf.

![ai-trash demo](assets/demo.gif)

## The problem

AI agents are useful but occasionally delete the wrong file. By the time you notice, it's gone. `ai-trash` intercepts every `rm` call at the system level so there's always a recovery window, without changing how you or your scripts use `rm`.

## How it works

- `/usr/local/bin/rm` (or `/opt/homebrew/bin/rm` on Apple Silicon) is replaced with a wrapper. Since that directory precedes `/bin` in the default PATH, all `rm` calls — from your shell, scripts, build tools, and AI agents — go through it automatically.
- **macOS**: files on the boot volume go directly to `~/.Trash/` via `NSFileManager`, so Finder's **Put Back** works out of the box. They are tagged with `com.ai-trash.*` extended attributes so `ai-trash list/restore/empty` can identify them. Files on external drives use `<volume>/.Trashes/<uid>/ai-trash/`.
- **Linux**: files go to `~/.local/share/Trash/ai-trash/`; other volumes use `<mountpoint>/.Trash-<uid>/ai-trash/`.
- **Windows**: a PowerShell `Remove-Item` function is dot-sourced from `$PROFILE` and routes deleted files to `%USERPROFILE%\.Trash\ai-trash\`.
- **Disposable files** (`.log`, `.tmp`, `.pyc`, `.swp`, etc.) and system temp directories (`/tmp`, `/var/folders`, caches) are permanently deleted immediately — no point accumulating junk.
- Each trashed item keeps its original filename. Name collisions are handled Finder-style: `file (2).txt`, `file (3).txt`.
- Metadata is stored as extended attributes on the file itself: original path, deletion time (UTC), who deleted it, and original size.
- A LaunchAgent runs every 6 hours and permanently purges items older than 30 days.
- **Daemon-safe**: if `$HOME` is unset or points to `/var/root` (system launchd daemons), the wrapper falls through to real `rm`. Non-interactive contexts (pipes, cron) never hang on `-i`/`-I` prompts.

## Protection modes

ai-trash has three modes, configured in `~/.config/ai-trash/config.sh`:

| Mode | Your `rm` calls | AI tool `rm` calls |
|------|----------------|-------------------|
| `selective` *(default)* | pass through to `/bin/rm` unchanged | → ai-trash |
| `safe` | → system Trash (recoverable) | → ai-trash |
| `always` | → ai-trash | → ai-trash |

`selective` is the default — your own commands behave exactly as before, only AI tool deletions are intercepted. `safe` is for anyone who wants nothing to silently disappear from the terminal. `always` gives you a full audit log of every CLI deletion.

Detection works by checking environment variables first (IDE terminals like Cursor and VS Code set `TERM_PROGRAM`), then walking the full process tree up to PID 1. Covered out of the box: Claude Code, Gemini CLI, Codex, Aider, Goose, OpenCode, Devin, Kiro CLI, OpenHands, GitHub Copilot CLI, Cursor, VS Code, Windsurf, and Warp. Add your own tools in the config file.

## Requirements

**macOS**
- macOS Monterey 12+ (Ventura 13+, Sonoma 14+ also tested)
- Bash 3.2+ (ships with macOS)
- Python 3 (for NSFileManager Put Back support — falls back to legacy behaviour without it)
- `/usr/local/bin` (Intel) or `/opt/homebrew/bin` (Apple Silicon) must precede `/bin` in PATH

**Linux**
- Bash 4.0+
- `/usr/local/bin` in PATH before `/bin`

**Windows**
- PowerShell 5.1+ or PowerShell 7+
- `$PROFILE` must be loaded in your sessions (the installer handles this)

## Install

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/forethought-studio/ai-trash/main/install.sh | bash
```

Or if you prefer to inspect before running:

```bash
git clone https://github.com/forethought-studio/ai-trash.git
cd ai-trash && ./install.sh
```

The installer copies `rm_wrapper.sh`, `ai-trash`, and `ai-trash-cleanup` to the bin directory, symlinks `rm` and `rmdir` to the wrapper, and sets up the cleanup scheduler (LaunchAgent on macOS, cron on Linux).

**Windows (PowerShell)**

```powershell
git clone https://github.com/forethought-studio/ai-trash.git
cd ai-trash/windows
.\install.ps1
```

The installer copies the scripts to `$env:USERPROFILE\.ai-trash\`, dot-sources the wrapper from your `$PROFILE`, and registers a scheduled task that runs every 6 hours to purge items older than 30 days.

## Usage

`rm` works exactly as before — no change to your workflow.

```bash
rm myfile.txt          # moves to ~/.Trash/ (macOS) or ~/.Trash/ai-trash/ (Linux) — recoverable
rm -rf build/          # same — whole directory is recoverable
rm *.log               # .log files are disposable → permanently deleted
find . -name "*.bak" | xargs rm   # works correctly — files are trashed, no hanging
```

### What it looks like

```
$ ai-trash list
NAME                                  DELETED (UTC)         SIZE   BY          ORIGINAL PATH
------------------------------------  --------------------  -----  ----------  ------------------------------
config.json                           2026-03-21 14:22:10   2.1K   user        /Users/user/dev/myapp/config.json
server.js                             2026-03-21 14:22:11   18.4K  claude      /Users/user/dev/myapp/server.js
migrations/                           2026-03-20 09:15:33   dir    cursor      /Users/user/dev/myapp/db/migrations

3 item(s) in AI trash

$ ai-trash restore server.js
restored → /Users/user/dev/myapp/server.js
```

### ai-trash CLI

```bash
ai-trash list                      # show all trashed items
ai-trash restore myfile.txt        # restore to original location
ai-trash empty                     # permanently delete all AI trash (confirms first)
ai-trash empty --force             # skip confirmation
ai-trash empty --older-than 7      # delete only items older than 7 days
```

### Recovery metadata

Each trashed item carries `com.ai-trash.*` extended attributes you can inspect directly:

```bash
# macOS (new-style — top-level ~/.Trash/)
xattr -p com.ai-trash.original-path  ~/.Trash/myfile.txt
xattr -p com.ai-trash.deleted-at     ~/.Trash/myfile.txt
xattr -p com.ai-trash.deleted-by     ~/.Trash/myfile.txt
xattr -p com.ai-trash.original-size  ~/.Trash/myfile.txt
xattr -p com.ai-trash.deleted-by-process  ~/.Trash/myfile.txt

# Linux / external drives
xattr -p com.ai-trash.original-path  ~/.local/share/Trash/ai-trash/myfile.txt
```

### Customising

The config file at `~/.config/ai-trash/config.sh` (installed automatically) controls the protection mode and which AI tools are recognised. It's well-commented — open it and everything is explained inline.

To add a tool not on the default list, find its process name with `ps aux | grep <toolname>` and add it to `AI_PROCESSES` or `AI_PROCESS_ARGS` in the config.


## Uninstall

**macOS / Linux**

```bash
./uninstall.sh
```

**Windows**

```powershell
.\windows\uninstall.ps1
```

Both uninstallers remove all installed files and leave your trash contents intact. Delete them manually if you want.

## What about safe-rm?

[safe-rm](https://launchpad.net/safe-rm) protects specific paths from being deleted at all — it doesn't trash anything. [trash](https://hasseg.org/trash/) is a standalone command that moves files to the macOS Trash but doesn't replace `rm`. Neither handles daemon safety, disposable classification, per-volume routing, recovery metadata, or the `ai-trash` CLI.

## License

MIT — see [LICENSE](LICENSE). Your copyright notice must be retained in any copy or fork.

If you use ai-trash in a commercial product, a mention in your documentation or credits would be appreciated.
