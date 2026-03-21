# ai-trash — project context for Claude Code

## What this is

A transparent `rm`/`rmdir` replacement for macOS that routes deleted files to a recoverable trash folder instead of permanently deleting them. Built specifically to protect against AI coding assistants (Claude Code, Codex, Cursor, Copilot, etc.) accidentally deleting files.

## Repo structure

```
rm_wrapper.sh               # Core wrapper — replaces /usr/local/bin/rm and /usr/local/bin/rmdir
ai-trash                    # CLI: ai-trash list / restore / empty
ai-trash-cleanup            # Runs every 6h via LaunchAgent, purges items >30 days old
com.ai-trash.cleanup.plist  # LaunchAgent template
install.sh                  # Installer (handles Intel + Apple Silicon)
uninstall.sh                # Reverses the install cleanly
```

## How it works

- `/usr/local/bin/rm` is a symlink → `rm_wrapper.sh`
- `/usr/local/bin/rmdir` is a symlink → `rm_wrapper.sh` (script detects mode via `$SCRIPT_NAME`)
- Wrapper classifies files as **disposable** (permanently deleted) or **trash** (moved to ai-trash)
- Boot volume trash: `~/.Trash/ai-trash/` — nested inside macOS Trash, visible in Finder
- Other volumes: `<mountpoint>/.Trashes/<uid>/ai-trash/` — macOS per-volume convention
- Each trashed item keeps its original filename; collisions handled Finder-style (`file (2).txt`)
- Metadata stored as xattrs on the file itself (no wrapper directories)

## xattrs written to every trashed file

| xattr | Example value |
|---|---|
| `com.ai-trash.original-path` | `/Users/user/dev/myapp/server.js` |
| `com.ai-trash.deleted-at` | `2026-03-21T16:09:49Z` |
| `com.ai-trash.deleted-by` | `user` |
| `com.ai-trash.deleted-by-process` | `claude` |
| `com.ai-trash.original-size` | `18432` (bytes, files only) |

## Disposable patterns (permanently deleted, not trashed)

Defined in `DISPOSABLE_PATTERNS` array at top of `rm_wrapper.sh`:
`.log .tmp .swp .swo .bak .orig .pyc .class *~ #*# .DS_Store` and pyenv shims.

Also permanently deleted: `/tmp`, `/var/folders`, `$TMPDIR`, `~/Library/Caches/`.

## Safety guards

- `$HOME` unset or `/var/root` → falls through to real `rm` (launchd system daemons)
- No TTY → `-i`/`-I` prompts suppressed (pipes, cron, launchd user agents)
- Read-only/inaccessible volume → falls through to real `rm` with a warning to stderr
- `--help`, `-h`, `-P`, `--version`, invalid flags → passed through to `/bin/rm`

## Installed locations (manual install)

- Apple Silicon: `/opt/homebrew/bin/`
- Intel: `/usr/local/bin/`
- LaunchAgent: `~/Library/LaunchAgents/com.ai-trash.cleanup.plist`
- Cleanup script: same bin dir as above

## Current version

`v1.0.1` — tagged and released on GitHub at https://github.com/forethought-studio/ai-trash

## Next planned work

- Homebrew formula submission to homebrew-core
  - Formula needs: stable tarball URL (v1.0.1), `test do` block calling `ai-trash --version`, no sudo, LaunchAgent via `brew services`
  - Apple Silicon installs to `/opt/homebrew/bin`; Intel to `/usr/local/bin` — Homebrew handles this automatically via its prefix

## Owner

GitHub: forethought-studio
