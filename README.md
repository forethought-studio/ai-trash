# ai-trash — Recover files deleted by AI coding tools

[![Test macOS / Linux](https://github.com/forethought-studio/ai-trash/actions/workflows/test-macos.yml/badge.svg)](https://github.com/forethought-studio/ai-trash/actions/workflows/test-macos.yml)
[![Test Windows PowerShell](https://github.com/forethought-studio/ai-trash/actions/workflows/test-windows.yml/badge.svg)](https://github.com/forethought-studio/ai-trash/actions/workflows/test-windows.yml)

A safe `rm` replacement that intercepts file deletions by AI coding assistants — Claude Code, Codex, Cursor, Copilot, and others — and moves them to a recoverable trash instead of permanently destroying them. Works transparently on macOS, Linux, and Windows with zero workflow changes.

![ai-trash demo](assets/demo.gif)

## The problem

AI coding agents delete the wrong file more often than you'd expect. By the time you notice, `rm` has already destroyed it and there's no undo. `ai-trash` intercepts every `rm` call at the system level so deleted files are always recoverable, without changing how you or your scripts use `rm`.

## How it works

- `/usr/local/bin/rm` (or `/opt/homebrew/bin/rm` on Apple Silicon) is replaced with a wrapper. Since that directory precedes `/bin` in the default PATH, all `rm` calls — from your shell, scripts, build tools, and AI agents — go through it automatically.
- **macOS**: files on the boot volume go directly to `~/.Trash/` via `FSMoveObjectToTrashSync` (CoreServices), so Finder's **Put Back** works out of the box. They are tagged with `com.ai-trash.*` extended attributes so `ai-trash list/restore/empty` can identify them. Files on external drives use `<volume>/.Trashes/<uid>/ai-trash/`.
- **Linux**: files go to `~/.local/share/Trash/ai-trash/`; other volumes use `<mountpoint>/.Trash-<uid>/ai-trash/`.
- **Windows**: a PowerShell `Remove-Item` function is dot-sourced from `$PROFILE` and routes deleted files to the **Windows Recycle Bin** via `Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile`. A JSON manifest at `%USERPROFILE%\.config\ai-trash\manifest.json` tracks each deletion so `ai-trash list/restore/empty` can find and recover items. Explorer's native "Restore" also works, since the files are in the real Recycle Bin.
- Each trashed item keeps its original filename. Name collisions are handled Finder-style: `file (2).txt`, `file (3).txt`.
- Metadata is stored as extended attributes on the file itself: original path, deletion time (UTC), who deleted it, and original size.
- AI-originated `find -delete`, destructive `git` commands, and local `rsync --delete` are also protected. Rsync protection uses rsync backups, so destination files that are deleted or replaced by the sync can be restored.
- A LaunchAgent runs every 6 hours and permanently purges items older than `RETENTION_DAYS` (default: 30 days, configurable in `~/.config/ai-trash/config.sh`). It then evicts the oldest items until the trash is under both `MAX_TRASH_SIZE_GB` (default: 5% of the disk, capped at 50 GiB) and `MAX_TRASH_ITEMS` (default: 25,000 items). The item cap matters on its own: Finder re-enumerates `~/.Trash` entry by entry to keep its size and Dock badge current, so a trash full of tiny agent-generated files can pin a CPU core long before it is anywhere near the size cap. Items trashed within the last `SIZE_EVICTION_GRACE_HOURS` (default: 24) are exempt from cap eviction, so nothing is destroyed before you have had a chance to restore it.
- **Daemon-safe**: if `$HOME` is unset or points to `/var/root` (system launchd daemons), the wrapper falls through to real `rm`. Non-interactive contexts (pipes, cron) never hang on `-i`/`-I` prompts.

## Protection modes

ai-trash has three modes, configured in `~/.config/ai-trash/config.sh`:

| Mode | Your `rm` calls | AI tool `rm` calls |
|------|----------------|-------------------|
| `selective` *(default)* | pass through to `/bin/rm` unchanged | → ai-trash |
| `safe` | → system Trash (recoverable, with Put Back, tracked by ai-trash) | → ai-trash |

`selective` is the default — your own commands behave exactly as before, only AI tool deletions are intercepted. `safe` routes your own deletions to the system Trash and tags them with ai-trash metadata, so `ai-trash list` shows everything and nothing silently disappears.

Detection works by checking environment variables first (IDE terminals like Cursor and VS Code set `TERM_PROGRAM`), then walking the full process tree up to PID 1. Covered out of the box: Claude Code, Gemini CLI, Codex, Aider, Goose, OpenCode, Devin, Kiro CLI, OpenHands, GitHub Copilot CLI, Cursor, VS Code, Windsurf, and Warp. Add your own tools in the config file.

## Requirements

**macOS**
- macOS Monterey 12+ (Ventura 13+, Sonoma 14+ also tested)
- Bash 3.2+ (ships with macOS)
- Python 3 (for Put Back support via `FSMoveObjectToTrashSync` — falls back to plain move without it)
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
find . -name "*.bak" | xargs rm   # works correctly — files are trashed, no hanging
rsync -a --delete src/ dest/       # AI calls preserve deleted/replaced destination files
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

On macOS and Linux, each trashed item carries `com.ai-trash.*` extended attributes you can inspect directly:

```bash
# macOS (top-level ~/.Trash/)
xattr -p com.ai-trash.original-path  ~/.Trash/myfile.txt
xattr -p com.ai-trash.deleted-at     ~/.Trash/myfile.txt
xattr -p com.ai-trash.deleted-by     ~/.Trash/myfile.txt
xattr -p com.ai-trash.original-size  ~/.Trash/myfile.txt
xattr -p com.ai-trash.deleted-by-process  ~/.Trash/myfile.txt   # e.g. "claude --resume abc123"

# Linux / external drives
xattr -p com.ai-trash.original-path  ~/.local/share/Trash/ai-trash/myfile.txt
```

On Windows, metadata is stored in a JSON manifest instead:

```powershell
Get-Content "$env:USERPROFILE\.config\ai-trash\manifest.json" | ConvertFrom-Json
```

### Customising

The config file at `~/.config/ai-trash/config.sh` (installed automatically) controls the protection mode and which AI tools are recognised. It's well-commented — open it and everything is explained inline.

### Which tools count as AI

Three shipped lists decide whether a caller is an AI tool: environment variables (`AI_ENV_VARS`), process names (`AI_PROCESSES`), and command-line substrings (`AI_PROCESS_ARGS`). Run `ai-trash detection` to see them.

Like the bypass patterns, they live in `ai-trash-lib.sh` rather than your config, so a tool added in a new release starts being recognised as soon as you upgrade. Your config holds only your own entries:

| Setting | Purpose |
| --- | --- |
| `AI_ENV_VARS`, `AI_PROCESSES`, `AI_PROCESS_ARGS` | Tools of your own, merged on top of the shipped lists. To add one, find its process name with `ps aux \| grep <toolname>`, or open a terminal inside it and run `echo $TERM_PROGRAM`. |
| `DISABLE_BUILTIN_AI_DETECTION` | Shipped entries to stop matching, by exact string. Useful for generic names: ai-trash ships `q` for Amazon Q Developer CLI, which also matches any other `q` on your PATH. |
| `USE_BUILTIN_AI_DETECTION=false` | Detect only the tools you listed yourself. |

Detection and bypass fail in opposite directions on purpose. An unreadable `USE_BUILTIN_AI_DETECTION` leaves detection **on**, and an unreadable `USE_BUILTIN_BYPASS_PATTERNS` leaves bypassing **off** -- because detecting a tool adds protection while bypassing a path deletes permanently. Both rules keep your file.

### Bypass patterns

Some paths have no recovery value and would only bloat the trash: git lock files, `node_modules`, `DerivedData`, `__pycache__`, and the scratch state AI tools write and delete constantly. On one profiled machine a single AI tool's ephemeral snapshots were 90.4% of everything trashed in a retention window. ai-trash ships about eighty patterns for these; a matching path is permanently deleted instead of trashed.

Run `ai-trash bypass-patterns` to see the live list and where each entry came from.

The shipped list lives in `ai-trash-lib.sh`, not in your config file, so upgrading gets you new defaults automatically. Your config is never overwritten, and holds only your own choices:

| Setting | Purpose |
| --- | --- |
| `BYPASS_TRASH_PATTERNS` | Extra patterns of your own, on top of the shipped ones. `ai-trash suggest` reads your actual trash and prints ready-to-paste entries. |
| `DISABLE_BUILTIN_BYPASS_PATTERNS` | Shipped patterns to turn off, by exact string copied from `ai-trash bypass-patterns`. |
| `USE_BUILTIN_BYPASS_PATTERNS=false` | Ignore the shipped list entirely. With no additions of your own, nothing is ever permanently deleted. |

Patterns are extended regular expressions matched against the file's resolved absolute path.


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

## Known limitations

- **macOS App Sandbox blocks wrapper execution.** Sandboxed apps (those with an `APP_SANDBOX_CONTAINER_ID` entitlement) cannot execute binaries from `/usr/local/bin/` or `/opt/homebrew/bin/`. The OS rejects the `exec` before the wrapper script starts running. This is a macOS platform constraint, not an ai-trash bug.
- **Workaround for sandboxed apps:** Use absolute paths (`/bin/rm`, `/usr/bin/find`) instead of bare `rm`/`find`. This bypasses the wrapper entirely.
- **Defense-in-depth:** If a partial sandbox allows the script to start, the wrappers detect `APP_SANDBOX_CONTAINER_ID` and pass through to the real binary immediately.

## Compared to other tools

| Tool | Trashes files | Replaces `rm` | AI-aware | Recovery CLI | Cross-platform |
|------|:---:|:---:|:---:|:---:|:---:|
| **ai-trash** | Yes | Yes | Yes | Yes | macOS, Linux, Windows |
| [safe-rm](https://launchpad.net/safe-rm) | No (blocks deletion) | Yes | No | No | Linux |
| [trash-cli](https://github.com/andreafrancia/trash-cli) | Yes | No | No | Yes | Linux |
| [trash](https://hasseg.org/trash/) | Yes | No | No | No | macOS |
| [rm-protection](https://github.com/alanzchen/rm-protection) | No (blocks deletion) | Yes | No | No | macOS, Linux |

## FAQ

**Claude Code / Cursor / Copilot deleted my files — can I get them back?**
If ai-trash was installed before the deletion, run `ai-trash list` to see all recoverable files and `ai-trash restore <filename>` to put them back. If ai-trash wasn't installed yet, install it now to prevent future losses.

**Does this slow down `rm`?**
The overhead is a few milliseconds for the process-tree check. Build tools, CI pipelines, and interactive use are unaffected in practice.

**Does it work with `find -delete`, `git clean`, and `rsync --delete`?**
Yes. ai-trash also ships wrappers for `find`, `git`, and `rsync` that intercept `-delete`, `git clean`, `git checkout -- .`, `git reset --hard`, and `rsync --delete` when run by AI tools. Rsync uses backups, so files removed or overwritten in the destination are recoverable from `ai-trash list`.

**Can I use it as a general safe-rm for all deletions, not just AI?**
Yes — set `MODE=safe` in `~/.config/ai-trash/config.sh` and every `rm` call (yours included) will go to the system Trash instead of being permanent.

## License

MIT — see [LICENSE](LICENSE). Your copyright notice must be retained in any copy or fork.

If you use ai-trash in a commercial product, a mention in your documentation or credits would be appreciated.
