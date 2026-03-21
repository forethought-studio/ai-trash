# ai-trash marketing research
*Last updated: 2026-03-21*

## Where people are already hurting (reply opportunities)

### Hacker News threads — reply with ai-trash as a solution

| Thread | URL | Notes |
|--------|-----|-------|
| Show HN: Claude-File-Recovery (recover files from ~/.claude sessions) | https://news.ycombinator.com/item?id=47182387 | **Best reply target.** Active thread. ai-trash is complementary (prevention vs. recovery). |
| Claude Code wiped our production database with a Terraform command | https://news.ycombinator.com/item?id=47278720 | More about Terraform/infra, less about rm — probably not a good fit |
| Replit's CEO apologizes after AI agent wiped a company's codebase | https://news.ycombinator.com/item?id=44646151 | Prod DB/infra angle, not rm — skip |
| AI coding platform goes rogue during code freeze, deletes entire prod DB | https://news.ycombinator.com/item?id=44639695 | Same — infra, not local files — skip |

### DEV Community post — excellent reply target
- **"TIL: AI keeps using rm -rf on important files. Changed rm to trash"**
  URL: https://dev.to/yemreak/til-ai-keeps-using-rm-rf-on-important-files-changed-rm-to-trash-5hin
  Notes: Author already discovered the problem and solved it manually. ai-trash is a polished version of exactly what they did. Perfect fit for a reply.

### GitHub issues on anthropics/claude-code — possible reply targets
- `[BUG] Critical Bug: Claude Code executed 'rm -rf' and deleted project files unexpectedly` — https://github.com/anthropics/claude-code/issues/29082
- `[BUG] Claude Code deleted the directory on which it worked.` — https://github.com/anthropics/claude-code/issues/4331
  Notes: Replying on bug reports can look self-promotional. Only do it if the issue is open and unanswered.

### Reddit — findings
Searched r/ClaudeAI. Two candidates reviewed and ruled out:
- "Claude and me trying to recover a deleted file" (346 votes) — about using AI *for* recovery, not AI *causing* deletion. Off-topic.
- "Claude Cowork nuked my iCloud Drive documents" — person is venting after the fact. Dropping a link feels spammy.

Best Reddit opportunity: a thread where someone is asking "is there a way to prevent this?" rather than just venting.
Watch r/ClaudeAI, r/cursor for that framing. Don't force it.

---

## Show HN draft
*Post this as a new submission on news.ycombinator.com — "Show HN" posts are explicitly encouraged for your own projects.*

**Title:**
```
Show HN: ai-trash – transparent rm replacement that routes AI-deleted files to a recoverable trash
```

**Body (optional, shown as first comment):**
```
AI agents are useful but occasionally run rm on the wrong thing. By the time you notice, the file is gone.

ai-trash replaces /usr/local/bin/rm with a wrapper. In "selective" mode (default), it only intercepts rm calls that originate from an AI tool — your own terminal commands pass straight through to /bin/rm unchanged.

Files go to ~/.Trash/ai-trash/ with xattr metadata: original path, deletion time, who deleted it. You get a 30-day recovery window. The CLI lets you list, restore, or empty the trash.

GitHub: https://github.com/forethought-studio/ai-trash

Related: claude-file-recovery (https://github.com/...) recovers files from ~/.claude session history. ai-trash is prevention; that tool is recovery. They're complementary.
```

---

## Reply draft for claude-file-recovery HN thread (https://news.ycombinator.com/item?id=47182387)

```
Nice work — this is the recovery side of the problem.

I've been working on the prevention side: ai-trash replaces /usr/local/bin/rm with a wrapper that routes files deleted by AI tools to ~/.Trash/ai-trash/ instead of destroying them. In "selective" mode (the default), your own rm calls pass straight through unchanged — only AI tool deletions are intercepted.

Each trashed file keeps its original name and gets xattr metadata with the original path, deletion time, and which process deleted it. There's a CLI for listing, restoring, and emptying the trash.

https://github.com/forethought-studio/ai-trash

The two tools are complementary: ai-trash stops the silent destruction in the first place; claude-file-recovery is a fallback when something still slips through.
```

---

## Notes on approach
- Only reply to threads where people have the actual problem — not drive-by promotion
- The DEV Community post and the HN claude-file-recovery thread are the strongest fits
- Show HN is appropriate — HN explicitly invites "Show HN" posts for your own work
- Reddit: research first, only reply to existing help requests
