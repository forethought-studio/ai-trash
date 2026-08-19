# Where ai-trash keeps deleted files on macOS

Decision brief for task `t_260819_114641_631`. Nothing in the product changes
with this document. It exists to settle one owner question, which is the last
section.

Everything below was measured on 2026-08-19, not recalled:

- **Host** (the machine the problem was reported on): Apple M3 Max, 16 cores,
  macOS 26.6.1 build 25G76. Spotlight indexing is **disabled** on every local
  volume here (`mdutil -as`), and Time Machine has no destination
  (`tmutil destinationinfo` -> "No destinations configured").
- **VM** (the UTM CI VM, 6 cores, macOS 26.5.1 build 25F80): used for everything
  that needs Finder driven interactively, a trash that can be emptied without
  destroying the owner's real files, or a Spotlight-indexed volume. The host's
  `no-host-ui-automation.sh` hook blocks `osascript` on the host, for good
  reason: an earlier runner drove Finder on the owner's machine mid-workday.

Raw records and every script cited here live in
`deliverables/t_260819_114641_631/` on the machine the measurements were taken
on. That tree is gitignored (`.gitignore:20`), so the file names below are
pointers into it rather than into this repository; the numbers they produced are
reproduced inline here so the argument stands without them.

## The short version

| layout | where the 50,000 entries are | Finder, % of one core |
|---|---|---|
| baseline | store empty, `~/.Trash` at its real 220 | **1.3** |
| plain store | `~/.ai-trash/` | **1.7** |
| nested store | `~/.Trash/<subdir>/` | **1.4** |
| today | top level of `~/.Trash` | **100.1** |

The cost is a property of the **top level of `~/.Trash`**, not of `~/.Trash`,
and not of holding 50,000 files somewhere. Two different layouts remove it, and
the choice between them is not about CPU at all. It is about which of two
things ai-trash is willing to lose:

- the **plain store** gives up Finder integration, and silently enrolls every
  trashed file into Time Machine and Backblaze, which today skip `~/.Trash`;
- the **nested store** keeps those exclusions and the Trash mental model, but
  one click on Empty Trash destroys the entire store, ahead of `RETENTION_DAYS`
  and ahead of the eviction grace window.

Both give up Finder's "Put Back" for ai-trash items. That loss is not avoidable
on any layout that fixes the CPU cost, because Put Back is a property of the
directory an item sits in and nothing else. Proof is in section 2.

## 1. What the measurement says (the CPU claim, tested rather than assumed)

Rig: `deliverables/t_260819_114641_631/plain-store-cpu-rig.py`. Raw per-phase
records: `plain-store-cpu-measurements.jsonl`, console log `plain-store-run.log`.

Method, and why it is shaped this way. The sibling rig from task
`t_260816_110658_972` sampled **Finder alone**, which is exactly the blind spot
that makes "we moved the store, the problem is gone" an unsafe conclusion:
Spotlight, Time Machine, FSEvents, the backup client and any EndpointSecurity
client all see a plain directory too. So every sample here is a **system-wide
per-process CPU delta** (`ps -axo pid=,time=,comm=` before and after a real
60-second wall-clock window), and a daemon nobody thought to name in advance
still shows up in the top-movers list. The same 50,000 entries are **renamed**
between phases rather than recreated, so entry count, size, xattrs, mtimes and
inode identity are held constant and location is the only variable.

    phase                  entries       Finder   Dock   mds   mds_stores   fseventsd   backupd   bzserv   bztransmit
    baseline               220 / 0          1.3    0.1    0.4          0.0         1.1       0.0      0.7          0.0
    plain-store-seeded     220 / 50,003     1.7    0.2    0.9          0.0         2.5       0.0      1.1          0.0
    trash-subdir-seeded    221 / 50,000     1.4    0.2    0.7          0.0         1.8       0.1      1.0          0.0
    trash-seeded           50,222 / 0     100.1    0.2    0.6          0.0         1.9       0.0      0.9          0.0
    restored               221 / 0          1.3    0.2    0.6          0.0         1.6       0.1      0.7          0.0

(entries column is `~/.Trash` top level / store; all figures are % of one core
averaged over the 60-second window. `restored` is the teardown reading: with the
50,000 entries gone the machine returns to its 1.3% baseline, which is what makes
the 100.1% attributable to the entries rather than to anything the rig did.)

**Controls.** Per the estate rule that no search or test counts as evidence
until a control proves it could have returned the other answer:

- *Positive control, same run, same entries*: the `trash-seeded` phase moved the
  identical 50,000 entries to the top level of `~/.Trash` and the same sampler
  immediately read **100.1%**, reproducing the pathology and matching the
  independent 100.1% recorded at 50,190 entries by the earlier task. A sampler
  that reads 1.7% because it is broken cannot read 100.1% off the same entries
  a few minutes later in the same run.
- *Idle gate*: every reading except the deliberate `trash-seeded` one is taken
  only after Finder has been observed below 3% of a core over a 30-second poll,
  so no reading is hangover from the phase before it. Both the plain store and
  the nested store settled on the first poll (2.5% and 1.3%).
- *After-shock*: teardown removed 50,001 entries, and Finder then held ~101% of
  a core for fourteen consecutive 30-second polls, decayed through 91, 49, 50,
  50, 51, 28, and only read 1.2% about **eleven minutes** after the last entry
  was gone. That is why the gate exists: a naive "delete and re-measure" would
  have reported that an empty trash costs a full core. It is also a product
  fact worth carrying into any migration plan, since a bulk move out of
  `~/.Trash` costs that same eleven minutes of Finder.
- *Safety*: this rig never invokes `ai-trash-cleanup`, so no eviction path is
  reachable and the accident recorded in `INCIDENT-real-trash-items-destroyed.md`
  cannot recur here. It also refuses to start on leftover entries, gives every
  synthetic entry an mtime older than every real one (so a scheduled cleanup
  firing mid-run would consume synthetic entries first), and asserts that no
  pre-existing entry name is among those it touched. No pre-existing entry was
  removed; teardown reported 50,001 removed and 0 errors.

**What this does NOT settle, stated plainly.** Three axes could not be measured
on the host, and one of them is the axis most likely to make the answer "the
cost merely moved":

1. *Spotlight.* Indexing is disabled on every local volume of the host, so the
   0.0% readings for `mds_stores` and `mdworker` there are consistent with
   indexing being off and are not evidence about an indexed machine. This is
   closed separately on the VM in section 1a.
2. *Time Machine.* No destination is configured on the host, so `backupd` could
   not do work in any phase. What IS measurable, and decisive, is the exclusion
   status. See section 4.
3. *Backblaze.* `bzfilelist` scans on its own schedule, not inside a 15-minute
   window, so the upload cost of a plain store was not observed directly. Again
   the exclusion rules settle the question without needing the CPU number.

### 1a. Spotlight, closed on an indexed host

Rig: `spotlight-cost-rig.py`, run on the VM, where `mdutil -as` reports indexing
enabled on `/` and `/System/Volumes/Data`. 25,000 entries (the shipped
`MAX_TRASH_ITEMS` default, so the steady state a real install sits at), seeded
into `~/.ai-trash/`, then renamed into a non-hidden `~/ai-trash-visible/` as the
positive control, with `mdfind` sampled in both phases as an independent
channel. Raw records: `spotlight-cost-measurements-vm.jsonl`.

    phase       entries (hidden/visible)   mds   mds_stores   mdworker_shared   corespotlightd   Finder   mdfind hits (hidden / visible)
    baseline    0 / 0                      0.1          0.1               0.1              0.2      0.3    0 / 0
    hidden      25,000 / 0                 0.1          0.1               0.1              0.2     22.3    0 / 0
    visible     0 / 25,000                 0.1          0.1               0.0              0.1      0.1    0 / 25,000
    restored    0 / 0                      0.1          0.1               0.0              0.3      0.3    0 / 0

**Spotlight does not index the hidden store, and the control proves the channel
works.** `mdfind -onlyin ~/.ai-trash zqxjspotlightprobe` returned 0 hits against
25,000 files that all contain that token. The identical files, renamed into a
non-hidden sibling directory, returned **25,000** hits. Same machine, same
content, same inodes, the only difference being the leading dot. An `mdfind`
that returns 0 because Spotlight is broken cannot return 25,000 four minutes
later.

**No Spotlight process moved in any phase**, including the visible phase where
25,000 files genuinely were indexed: `mds`, `mds_stores`, `mdworker_shared` and
`corespotlightd` all stayed within 0.1 points of their baseline. So the
hypothesis that the cost merely relocates from Finder to the indexer is not
supported on either host, and on the indexed host the indexer never even sees
the store.

**The one anomaly, and its resolution.** Finder read 22.3% in the `hidden`
phase, which would have contradicted the host result. It does not, and the cause
is a methodological difference between the two rigs: this one slept a fixed 120
seconds after seeding instead of gating on Finder being idle. Re-run with a
settle curve (`vm-finder-settle-probe.py`, raw records in
`vm-finder-settle-measurements-vm.jsonl`, 0 Finder windows open, recorded in its
`start` record):

    pre-seed                                  0.8 %
    +30 s   after creating 25,000 files      89.1 %
    +60 s                                    99.8 %
    +90 s                                   100.2 %
    +120 s                                  100.1 %
    +150 s                                  100.0 %
    +180 s                                    1.8 %
    steady state, 60-second window            0.8 %   (25,000 entries still present)

So creating 25,000 files in a watched location costs Finder about two and a half
minutes of one core on a 6-core VM, and then nothing. The resident cost of the
plain store at 25,000 entries is its baseline, 0.8%. This is worth knowing for
its own sake: a bulk migration, or an agent deleting thousands of files in a
burst, produces a temporary Finder spike under any layout. Under the status quo
that spike does not decay, because the entries stay at the top level of
`~/.Trash` and Finder keeps re-enumerating them.

## 2. What is actually lost (Finder integration, tested on the VM)

### Put Back is a property of the directory, not of the file

`put-back-probe.sh` and `put-back-probe2.sh`, run on the VM. Two probe files,
identical except for where they end up: one moved by the same
`FSMoveObjectToTrashSync` call `ai-trash-lib.sh:1026` uses, one moved by `mv`
into `~/.ai-trash/` and tagged with ai-trash's own xattrs.

- Finder's trash count went **3 -> 4** when the first probe landed in `~/.Trash`,
  and `name of every item of trash` listed it. The plain-store probe did not
  raise the count and does not appear in that list, while `ls` confirms it is
  still on disk. Carrying `com.ai-trash.original-path` changes nothing:
  membership is a function of the directory.
- Moving an item that WAS in `~/.Trash` out to `~/.ai-trash` dropped the count
  back to **3** and removed it from Finder's trash; moving it back restored both.
  Nothing about the file changed in between.
- The Put Back records themselves are `ptbL` / `ptbN` entries inside
  **`~/.Trash/.DS_Store`**, keyed by entry name (decoded in
  `ds-store-ptb-records-vm.log`: records keyed by `probe-trash.txt` and
  `probe2-file.txt` alongside the VM's real trash entries). They stay behind in
  the trash's `.DS_Store` after the item leaves, and `~/.ai-trash/.DS_Store`
  does not exist. So an item moved out of `~/.Trash` does not carry its Put Back
  data with it, and one moved in does not acquire any.

Not proven: that the File menu's "Put Back" item is greyed out or absent, which
would have been the most user-legible form of the same fact. System Events
refused `osascript` assistive access on the VM (`-1719`), SIP is enabled there,
and granting it would mean editing another project's CI VM TCC state. Trash
membership plus the location of the metadata already determine the answer, so
this is a missing illustration rather than a missing link.

### The Dock badge and the Trash window

Both follow from the same membership result: items in a plain store are not
elements of Finder's `trash`, so they do not appear in the Trash window and do
not contribute to the Dock's full-trash state. Under the **nested** layout they
appear as exactly one folder in the Trash window, which is also what makes the
CPU cost vanish there.

### Empty Trash: the difference that actually separates the two candidates

`empty-trash-probe.sh`, run on the VM. Both layouts seeded, plus a normal
trashed file as a bystander, then Finder was told `empty trash`. Result
reproduced twice, on separate runs (`empty-trash-probe-vm.log`,
`empty-trash-probe-rerun-vm.log`):

    nested store dir  : DESTROYED
    nested store item : DESTROYED
    plain store item  : SURVIVED
    bystander in trash: DESTROYED
    Finder trash count: 0

Under the nested layout, one Empty Trash click permanently destroys the whole
ai-trash store, ahead of `RETENTION_DAYS` and ahead of the 24-hour eviction
grace window that exists precisely so nothing is destroyed before the user has a
chance to restore it. That is not a regression introduced by nesting: it is
**already true today**, because ai-trash items sit at the top level of
`~/.Trash`. But it is the one axis on which the plain store is strictly better
than both the nested layout and the status quo, and it is the axis the product
exists to serve.

macOS's own "Empty Trash automatically after 30 days" setting was not tested
here, but it acts on the same directory, so the same reasoning applies to it and
it fires without anyone clicking anything.

This evidence cost something and the brief should say so. The first run of that
probe emptied a VM trash that was not empty, destroying three sparse bundles
another project's tests had deleted earlier and left recoverable. They were
regenerable fixtures and no authored work was lost, but they were recoverable
before the probe and are not now. Cause, the recovery routes ruled out, and the
precondition now encoded in the script (it aborts, naming the entries, unless
`~/.Trash` holds nothing but the probe's own items) are in
`INCIDENT-vm-trash-emptied.md`. The guard was then verified in both directions:
a planted foreign entry produced a refusal, exit 1, and the entry still in the
trash afterwards; an empty trash let the probe run and reproduce the result
above.

### What happens to `FSMoveObjectToTrashSync`

`ai-trash-lib.sh:994-1105` routes boot-volume files through
`FSMoveObjectToTrashSync` in a batched Python helper precisely to get Put Back
for free, and falls back to `_mv_file_to_ai_trash_dir` when the call fails or
the file is on another volume (`ai-trash-lib.sh:1097`). Under either new layout
that call has nothing left to buy: it moves things to `~/.Trash` by definition,
and its output path is validated against `trash_prefix = home + '/.Trash/'`
(`ai-trash-lib.sh:1045`). It would be deleted, and the existing `mv` fallback
becomes the only path. Two things fall out for free: the boot-volume-only
special case disappears (one code path for all volumes instead of two), and the
`python3` dependency the README lists at line 44 ("for Put Back support") is no
longer required for trashing.

### The user who has never opened a terminal

Honest framing of the loss. Today that user has a real route: open Trash in
Finder, find the file, right-click, Put Back. Under either new layout that route
is gone and the only route is `ai-trash list` / `ai-trash restore` in a terminal.

Two things temper it, and one sharpens it:

- ai-trash is installed with `brew install` and a PATH change, and it exists to
  intercept `rm` from coding agents. A user who has never opened a terminal does
  not have it installed.
- At the shipped default the Trash window holds up to 25,000 mixed entries.
  Finding one specific agent-deleted file in that window and clicking Put Back
  is not a realistic recovery route; `ai-trash list | grep` is.
- Sharpening it: today Put Back also works for the *non-AI* `rm` calls that
  `safe` mode routes to the system trash. Those are ordinary user deletions at
  human volume and they should keep going to `~/.Trash` under any option here,
  which they do, since only the ai-trash store moves.

## 3. What ai-trash would have to own instead

`ai-trash restore` already works off `com.ai-trash.original-path` and is
location-independent (`cmd_restore`, `ai-trash:149`). Concretely, what changes:

| capability | today | after the move |
|---|---|---|
| item placement | `FSMoveObjectToTrashSync`, `mv` fallback (`ai-trash-lib.sh:994-1105`) | `mv` only; delete the CoreServices helper |
| store path | `BOOT_TRASH_DIR="$HOME/.Trash"` (`ai-trash-lib.sh:13`), `TRASH_DIR` (`ai-trash:12`), `scan_dir` (`ai-trash-cleanup`) | one new constant, three call sites |
| listing | `find -maxdepth 1 -xattrname com.ai-trash.original-path` over a mixed directory (`ai-trash:72-80`) | plain `find` over a directory that is ours by construction; the xattr filter can go, which also removes the reason the macOS and Linux branches differ |
| cleanup inventory | same xattr filter, then batched `stat` + `du -sk` (`ai-trash-cleanup:228`) | unchanged except for the scan directory |
| collision naming | `get_unique_trash_path` (`ai-trash-lib.sh:822`) | unchanged, already in-house |
| size accounting | `du -sk` batched | unchanged |
| Finder-visible affordance | free, via `~/.Trash` | **gone**; nothing replaces it without new UI |
| cross-volume | `<mp>/.Trashes/<uid>/ai-trash` (`ai-trash-lib.sh:795`) | becomes `<mp>/.ai-trash/` under the plain store; must stay per-volume either way, since moving to `$HOME` would copy bytes across volumes |
| uninstall | prints "your AI trash contents are still in ~/.Trash/ai-trash/" (`uninstall.sh:126`) | must name the real store, and that message is **already wrong today** for the boot volume, where items sit at the top level of `~/.Trash`, not in an `ai-trash` subdirectory |
| backup exclusion | free, inherited from `~/.Trash` | **new work under the plain store**; see section 4 |

One implementation detail that has to be decided rather than assumed: on this
host `~/.ai-trash/` **already exists and is already ai-trash's**, holding
`path-shadow-log.jsonl`, `path-shadow-scan.out` and `path-shadow-scan.err` from
the `com.ai-trash.path-shadow-scan` LaunchAgent. So the plain store cannot be
that directory as-is without mixing trashed items and log files in one namespace
where "everything here is a trashed item" is exactly the invariant that lets the
xattr filter go. The store wants to be a subdirectory of it (`~/.ai-trash/store/`
or similar), which costs nothing and keeps one ai-trash-owned directory in `$HOME`
rather than two. The measurement in section 1 put the 50,000 entries directly in
`~/.ai-trash/`, which is the shallower and therefore worse-case placement of the
two; section 1's nested-in-`~/.Trash` phase shows that going one level deeper
only ever reduces what Finder enumerates.

One relevant finding while checking this: the comment at `ai-trash:67` claims the
macOS iterator covers "new-style items in `~/.Trash/` (xattr-tagged) + legacy
`~/.Trash/ai-trash/`", but the code is `find -maxdepth 1`, so nested items are
not enumerated. Verified by running the real CLI against a synthetic `HOME`
holding one tagged item at each depth: `ai-trash list` reported
`1 item(s) in AI trash` and listed only the top-level one. This matters for
sizing the nested option, which needs that iterator to actually descend.

## 4. Backups: the plain store's hidden cost

`~/.Trash` is excluded from both backup products on this host. A plain store is
not:

    $ tmutil isexcluded ~/.Trash ~/.ai-trash
    [Excluded]  /Users/user/.Trash
    [Included]  /Users/user/.ai-trash

Backblaze ships `/.trash/` and `.trashes/` as **mandatory** exclusions
(`/Library/Backblaze.bzpkg/bzdata/bzexcluderules_mandatory.xml`); grepping both
the mandatory and the editable rule files for `ai-trash` returns nothing. The
external-drive rule excludes everything beginning with a period at the root of
an external volume, so a per-volume `<mp>/.ai-trash/` would stay excluded there;
the home-directory store would not.

So under the plain store, every file an agent deletes gets backed up and
uploaded for as long as it sits in the trash. Taking the profiling figures that
the item cap was set from (about 550 genuine deletions/day after the bypass
patterns, 30-day retention, and the ~167 KB average entry size recorded in
`config.default.sh:303`), that is on the order of 16,000 files and roughly 3 GB
continuously churning through Time Machine snapshots and Backblaze uploads, for
data whose entire purpose is to have been deleted.

This is real, it is not fatal, and it is fixable in the installer:
`tmutil addexclusion` handles Time Machine, and the Backblaze case needs a
documented user-side exclusion because the mandatory rule file is not ours to
edit. It has to be counted as required scope of the plain-store option rather
than as a footnote.

The nested layout inherits both exclusions and needs none of that work.

## 5. Migration

Existing installs have items sitting at the top level of `~/.Trash`, tagged with
`com.ai-trash.original-path`. Three properties of those items were verified
rather than assumed:

- **Metadata survives a move.** The rig's synthetic entries were renamed twice
  (`~/.ai-trash` -> `~/.Trash/<subdir>` -> `~/.Trash`) and still carried both
  `com.ai-trash.original-path` and `com.ai-trash.deleted-by`, with mtime intact,
  afterwards. A same-volume `mv` therefore preserves everything
  `ai-trash list` / `restore` depend on.
- **Put Back does not survive a move.** Section 2: the `ptb` records stay in
  `~/.Trash/.DS_Store`. Any item migrated into a new store loses Put Back at the
  moment it is migrated, even though it had it a second earlier.
- **They are still findable in place.** The current iterator selects on the
  xattr, so a compatibility scan of `~/.Trash` costs one extra `find`.

Recommended migration, which the owner is not being asked to choose between,
because the options are not equivalent:

1. New items go to the new store from the moment of upgrade.
2. Existing tagged items in `~/.Trash` are **left where they are** and continue
   to be listed, restored and purged by `ai-trash-cleanup` under the existing
   `RETENTION_DAYS`, so they age out naturally within 30 days.
3. The compatibility scan is kept for one release cycle and then removed.

Reasoning: bulk-moving a live user's trash is a destructive operation performed
for cosmetic tidiness, it strips Put Back from items that still have it, and it
buys nothing the user can perceive, since `ai-trash list` shows both locations
during the overlap. Leaving them costs one `find` per cleanup run for 30 days.
What the user sees: nothing, except that items deleted before the upgrade still
have Put Back and items deleted after it do not.

## 6. The three options, with their real costs

**A. Plain store, `~/.ai-trash/`.**
CPU cost: gone (1.7% at 50,000 entries, measured). Put Back: gone. Trash window
and Dock badge: gone. Empty Trash and macOS auto-empty: **can no longer destroy
the store**, which is a genuine gain in the one capability the product exists to
provide. New work: the store path, deleting the CoreServices helper, and backup
exclusions for Time Machine and Backblaze that today come for free.

**B. Nested store, `~/.Trash/ai-trash/`.**
CPU cost: gone (1.4% at 50,000 entries, measured). Put Back: gone, exactly as in
A. Trash window: one folder, which is arguably tidier than 25,000 loose entries.
Backup exclusions: inherited, no work. Empty Trash: destroys the entire store in
one click, ahead of retention and the grace window, as it does today. New work:
the store path, deleting the CoreServices helper, and making the CLI iterator
actually descend (see section 3, where it currently does not).

**C. Keep the top level of `~/.Trash` (status quo).**
CPU cost: about 23% of one core continuously at the shipped 25,000 cap, measured
in the previous task, for as long as ai-trash is doing its job on a host at the
profiled intake. Put Back: kept. Everything else: unchanged. Buying that 23%
back by lowering the cap means destroying recoverable files sooner, which is the
one lever that trades away the product's purpose, so it is not a real mitigation.

## 7. Follow-up ledger

- **Resolved here.** Whether Finder's cost is inherent to `~/.Trash` (no: it is
  inherent to its top level). Whether a plain store costs another daemon
  instead (no daemon moved on either host; see 1 and 1a). Whether Put Back
  survives outside `~/.Trash` (it does not, and the mechanism is now known).
  Whether Empty Trash reaches each layout (nested yes, plain no). Whether the
  metadata survives migration (yes). Whether backups change (yes, and only for
  the plain store).
- **Queued.** One, and it is not downstream of the decision:
  `t_260819_130754_054` (`q show c4`), fixing three shipped strings that tell the
  user their items are in `~/.Trash/ai-trash/` when on the boot volume they are
  at the top level of `~/.Trash`: the uninstaller message (`uninstall.sh:126`),
  the installer's example path (`install.sh:183`), and the stale iterator comment
  (`ai-trash:67`). All three are wrong today under option C as well, so the task
  stands whatever the answer below is. Nothing else is queued: every other piece
  of implementation work here is downstream of a decision the owner has not made,
  and if the answer is C it is all garbage.
- **Owner call.** One, stated below.

## 8. Recommendation, and the question

**Recommendation: A, the plain store at `~/.ai-trash/`, with the Time Machine
and Backblaze exclusions counted as part of the work rather than as a follow-up.**

The CPU evidence does not choose between A and B: both remove the cost
completely, and both lose Put Back. The tiebreaker is what each does to
recoverability, which is the entire point of the product. Under B (and under C)
a single Empty Trash click, or macOS's own 30-day auto-empty, permanently
destroys every recoverable file ai-trash is holding, ahead of `RETENTION_DAYS`
and ahead of the grace window that was deliberately built to prevent exactly
that. Under A it cannot. That is a data-loss axis. B's advantage over A is a
resource axis: backup and upload volume, which is unpleasant but costs nobody
their work, and which one `tmutil addexclusion` plus a documented Backblaze rule
largely closes. A data-loss risk that cannot be mitigated outranks a resource
cost that can.

The strongest argument against A is that it takes deleted files out of the place
every Mac user expects to find them. Section 2 is the honest answer: that
expectation is already not being served here, because the route it implies
(scan the Trash window, click Put Back) does not survive 25,000 entries, and the
person it serves does not have a PATH-shimmed `rm` interceptor installed.

**The question: should ai-trash stop putting items at the top level of
`~/.Trash` on macOS, and if so, into which store?**

- **A. Under `~/.ai-trash/` (recommended).** Costs Put Back and the Trash
  window, gains immunity from Empty Trash and from macOS auto-empty, requires
  new Time Machine and Backblaze exclusions. The exact path is a subdirectory
  such as `~/.ai-trash/store/`, since `~/.ai-trash/` already holds ai-trash's
  path-shadow-scan logs (section 3).
- **B. `~/.Trash/ai-trash/`.** Costs Put Back and the Trash window listing,
  keeps backup exclusions for free, leaves the store destroyable by one click.
- **C. Change nothing.** Keeps Put Back, keeps about 23% of a core burning
  continuously at the shipped default.
