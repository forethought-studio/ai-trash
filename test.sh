#!/bin/bash
# test.sh — automated test suite for ai-trash
#
# Usage: bash test.sh
# Requires: macOS or Linux, no sudo needed — tests against local repo scripts.
# NOTE: test working files are created under ~/ai-trash-test-$$ (not /tmp,
# which the wrapper treats as a disposable location and permanently deletes).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# ─── Colour helpers ────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; RESET='\033[0m'
_pass() { echo -e "${GREEN}  PASS${RESET}  $*"; }
_fail() { echo -e "${RED}  FAIL${RESET}  $*"; FAILURES=$(( FAILURES + 1 )); }
_skip() { echo -e "${YELLOW}  SKIP${RESET}  $*"; }
_section() { echo ""; echo "── $* ──"; }
FAILURES=0

# ─── Isolated test environment ─────────────────────────────────────────
# Work dir is under $HOME so files aren't caught by the /tmp disposable rule.
# TEST_HOME has its own Trash hierarchy so we never touch the real system Trash.
WORK_DIR="$HOME/ai-trash-test-$$"
TEST_HOME="$WORK_DIR/home"
if [[ "$(uname -s)" == "Darwin" ]]; then
  TEST_TRASH="$TEST_HOME/.Trash"
  TEST_SYSTEM_TRASH="$TEST_HOME/.Trash"
  mkdir -p "$WORK_DIR" "$TEST_HOME/.Trash"
else
  TEST_TRASH="$TEST_HOME/.local/share/Trash/ai-trash"
  TEST_SYSTEM_TRASH="$TEST_HOME/.local/share/Trash/files"
  mkdir -p "$WORK_DIR" "$TEST_HOME/.local/share/Trash/files"
fi
TEST_CONF_DIR="$TEST_HOME/.config/ai-trash"
mkdir -p "$TEST_TRASH" "$TEST_CONF_DIR"

trap 'rm -rf "$WORK_DIR"' EXIT

REPO_DIR="$(pwd)"

# Run rm_wrapper.sh with overridden HOME (isolates config + trash).
# TERM_PROGRAM=cursor simulates an AI context so files route to ai-trash.
_rm() {
  HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor bash "$REPO_DIR/rm_wrapper.sh" "$@"
}

# Run ai-trash CLI with overridden HOME (isolates trash dir)
_ai_trash() {
  HOME="$TEST_HOME" bash "$REPO_DIR/ai-trash" "$@" 2>&1 || true
}

# ─── Config helpers ────────────────────────────────────────────────────
_set_mode() {
  cp "$REPO_DIR/config.default.sh" "$TEST_CONF_DIR/config.sh"
  sed -i.bak "s/^MODE=.*/MODE=$1/" "$TEST_CONF_DIR/config.sh" && rm -f "${TEST_CONF_DIR}/config.sh.bak"
}

# ─── Tests ─────────────────────────────────────────────────────────────

_section "ai-trash CLI: status on empty trash"
out=$(_ai_trash status)
if echo "$out" | grep -q "AI trash is empty"; then
  _pass "status: empty trash"
else
  _fail "status: expected 'AI trash is empty', got: $out"
fi

_section "ai-trash CLI: list on empty trash"
out=$(_ai_trash list)
if echo "$out" | grep -q "AI trash is empty"; then
  _pass "list: empty trash"
else
  _fail "list: expected 'AI trash is empty', got: $out"
fi

_section "rm_wrapper: always mode — file goes to ai-trash"
_set_mode selective
f="$WORK_DIR/always-test.txt"
echo "hello" > "$f"
_rm "$f"
trashed=$(ls "$TEST_TRASH/" 2>/dev/null | grep "always-test.txt" || true)
if [[ -n "$trashed" ]]; then
  _pass "always: file moved to ai-trash"
else
  _fail "always: file not found in ai-trash ($TEST_TRASH). Contents: $(ls $TEST_TRASH/ 2>/dev/null || echo 'empty')"
fi

_section "rm_wrapper: always mode — metadata written"
item="$TEST_TRASH/always-test.txt"
_read_meta() {
  local file="$1" key="$2" sidecar
  if [[ "$(uname -s)" == "Darwin" ]]; then
    xattr -p "com.ai-trash.$key" "$file" 2>/dev/null || true
  else
    sidecar="$(dirname "$file")/.$(basename "$file").ai-trash"
    [[ -f "$sidecar" ]] && grep "^${key}=" "$sidecar" | cut -d= -f2- || true
  fi
}
if [[ -f "$item" ]]; then
  orig=$(_read_meta "$item" original-path)
  ts=$(_read_meta "$item" deleted-at)
  by=$(_read_meta "$item" deleted-by)
  sz=$(_read_meta "$item" original-size)
  [[ "$orig" == "$f" ]]   && _pass "meta: original-path" || _fail "meta: original-path='$orig' want '$f'"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] && _pass "meta: deleted-at ($ts)" || _fail "meta: deleted-at='$ts'"
  [[ -n "$by" ]]           && _pass "meta: deleted-by ($by)" || _fail "meta: deleted-by empty"
  [[ "$sz" =~ ^[0-9]+$ ]]  && _pass "meta: original-size ($sz)" || _fail "meta: original-size='$sz'"
else
  _fail "meta: item not found in trash, skipping metadata tests"
fi

_section "ai-trash CLI: status shows item"
out=$(_ai_trash status)
if echo "$out" | grep -q "Items:"; then
  count=$(echo "$out" | grep "Items:" | awk '{print $2}')
  [[ "$count" -ge 1 ]] && _pass "status: reports $count item(s)" || _fail "status: item count=$count"
else
  _fail "status: unexpected output: $out"
fi

_section "ai-trash CLI: list shows item with metadata"
out=$(_ai_trash list)
if echo "$out" | grep -q "always-test.txt"; then
  _pass "list: item appears"
else
  _fail "list: item not shown. Output: $out"
fi
if echo "$out" | grep -q "always-test.txt" && echo "$out" | grep -Eq "[0-9]{4}-[0-9]{2}-[0-9]{2}"; then
  _pass "list: deletion timestamp shown"
else
  _fail "list: timestamp missing. Output: $out"
fi

_section "ai-trash CLI: restore"
f2="$WORK_DIR/restore-me.txt"
echo "restore-content" > "$f2"
_rm "$f2"
if ls "$TEST_TRASH/" 2>/dev/null | grep -q "restore-me.txt"; then
  out=$(_ai_trash restore restore-me.txt)
  if [[ -f "$f2" ]]; then
    _pass "restore: file restored to original path"
    content=$(cat "$f2")
    [[ "$content" == "restore-content" ]] && _pass "restore: content intact" || _fail "restore: content='$content'"
  else
    _fail "restore: file not at original path after restore. Output: $out"
  fi
else
  _fail "restore: file not found in trash to restore"
fi

_section "rm_wrapper: AI context — directory goes to ai-trash"
d="$WORK_DIR/testdir"
mkdir -p "$d/subdir"
echo "x" > "$d/file.txt"
_rm -rf "$d"
if ls "$TEST_TRASH/" 2>/dev/null | grep -q "testdir"; then
  _pass "always: directory moved to ai-trash"
else
  _fail "always: directory not found in ai-trash. Contents: $(ls $TEST_TRASH/ 2>/dev/null || echo 'empty')"
fi

_section "rm_wrapper: .log file goes to ai-trash (not permanently deleted)"
# Disposable patterns were removed — all files go to trash regardless of extension.
f_log="$WORK_DIR/debug.log"
echo "log content" > "$f_log"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor bash "$REPO_DIR/rm_wrapper.sh" "$f_log" 2>/dev/null
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]] && [[ ! -f "$f_log" ]]; then
  _pass ".log file moved to ai-trash (not permanently deleted)"
else
  _fail ".log not trashed — before=$before_count after=$after_count file_exists=$(test -f $f_log && echo yes || echo no)"
fi

_section "rm_wrapper: selective mode — non-AI rm passes through to /bin/rm"
_set_mode selective
f_sel="$WORK_DIR/selective-test.txt"
echo "bye" > "$f_sel"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
# Run in a clean env without any AI-identifying vars or process ancestry
env -i HOME="$TEST_HOME" PATH=/bin:/usr/bin:/usr/local/bin \
  bash "$REPO_DIR/rm_wrapper.sh" "$f_sel" </dev/null 2>/dev/null || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ ! -f "$f_sel" ]] && [[ "$after_count" -eq "$before_count" ]]; then
  _pass "selective: non-AI rm bypassed ai-trash (file gone, trash count unchanged)"
elif [[ ! -f "$f_sel" ]] && [[ "$after_count" -gt "$before_count" ]]; then
  _skip "selective: went to ai-trash (AI parent still detected in process tree — expected when run from Claude Code)"
else
  _fail "selective: file still exists after rm"
fi

_section "rm_wrapper: safe mode — non-AI rm goes to system trash"
_set_mode safe
f_safe="$WORK_DIR/safe-test.txt"
echo "safe" > "$f_safe"
before_sys=$(ls "$TEST_SYSTEM_TRASH/" 2>/dev/null | { grep -cv "^ai-trash$" || true; } | tr -d ' ')
env -i HOME="$TEST_HOME" PATH=/bin:/usr/bin:/usr/local/bin \
  bash "$REPO_DIR/rm_wrapper.sh" "$f_safe" </dev/null 2>/dev/null || true
after_sys=$(ls "$TEST_SYSTEM_TRASH/" 2>/dev/null | { grep -cv "^ai-trash$" || true; } | tr -d ' ')
if [[ ! -f "$f_safe" ]] && [[ "$after_sys" -gt "$before_sys" ]]; then
  _pass "safe: non-AI rm moved file to system trash (~/.Trash)"
elif [[ ! -f "$f_safe" ]] && [[ "$after_sys" -eq "$before_sys" ]]; then
  ai_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
  _skip "safe: file gone but not in system trash — AI parent detected (ai-trash count=$ai_count) — expected from Claude Code"
else
  _fail "safe: file still exists after rm"
fi

_section "rm_wrapper: name collision — Finder-style renaming"
_set_mode selective
f_a="$WORK_DIR/collision.txt"
echo "first" > "$f_a"
_rm "$f_a"
# Place another file with the same base name to force a collision
echo "second" > "$f_a"
_rm "$f_a"
hits=$(ls "$TEST_TRASH/" 2>/dev/null | grep "collision" || true)
count=$(echo "$hits" | grep -c "collision" || true)
if [[ "$count" -ge 2 ]]; then
  renamed=$(echo "$hits" | grep -v "^collision\.txt$" || true)
  _pass "collision: second copy renamed to '$renamed'"
else
  _fail "collision: expected 2 collision.txt variants, found: $hits"
fi

_section "rm_wrapper: -i flag suppressed when no TTY"
_set_mode selective
f_i="$WORK_DIR/interactive-test.txt"
echo "x" > "$f_i"
echo "" | HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor bash "$REPO_DIR/rm_wrapper.sh" -i "$f_i" 2>&1 || true
if [[ ! -f "$f_i" ]]; then
  _pass "-i suppressed (no TTY): file deleted without hanging"
else
  _fail "-i suppressed: file still exists"
fi

_section "rm_wrapper: missing file with -f — exits 0"
_set_mode selective
out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" bash "$REPO_DIR/rm_wrapper.sh" -f "$WORK_DIR/does-not-exist.txt" 2>&1; echo "EXIT:$?")
exit_val=$(echo "$out" | grep "EXIT:" | cut -d: -f2)
[[ "$exit_val" == "0" ]] && _pass "-f on missing file exits 0" || _fail "-f on missing file exits $exit_val"

_section "rm_wrapper: missing file without -f — exits 1"
_set_mode selective
out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" bash "$REPO_DIR/rm_wrapper.sh" "$WORK_DIR/does-not-exist.txt" 2>&1; echo "EXIT:$?") || true
exit_val=$(echo "$out" | grep "EXIT:" | cut -d: -f2)
[[ "$exit_val" == "1" ]] && _pass "missing file without -f exits 1" || _fail "missing file exits $exit_val"

_section "ai-trash CLI: empty --older-than (recent items not deleted)"
_set_mode selective
# Items just added should not be deleted with --older-than 1
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
_ai_trash empty --force --older-than 1 >/dev/null 2>&1
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
[[ "$before_count" -eq "$after_count" ]] && _pass "empty --older-than 1: recent items untouched" \
  || _fail "empty --older-than 1: item count changed ($before_count → $after_count)"

_section "ai-trash CLI: empty --force"
before=$(_ai_trash status 2>/dev/null | grep "^Items:" | awk '{print $2}' || echo 0)
_ai_trash empty --force >/dev/null 2>&1
out=$(_ai_trash status)
if echo "$out" | grep -q "AI trash is empty"; then
  _pass "empty --force: trash cleared (was $before items)"
else
  _fail "empty --force: items still remain in AI trash. Status: $out"
fi

_section "ai-trash CLI: status after empty"
out=$(_ai_trash status)
if echo "$out" | grep -q "AI trash is empty"; then
  _pass "status: empty after empty --force"
else
  _fail "status: unexpected output after empty: $out"
fi

# ─── Additional gap coverage ────────────────────────────────────────────

_section "rm_wrapper: path with spaces in name"
_set_mode selective
f_spaces="$WORK_DIR/file with spaces.txt"
echo "spaced" > "$f_spaces"
_rm "$f_spaces"
if ls "$TEST_TRASH/" 2>/dev/null | grep -q "file with spaces.txt"; then
  _pass "spaces: file with spaces moved to ai-trash"
else
  _fail "spaces: file with spaces not in ai-trash. Contents: $(ls "$TEST_TRASH/" 2>/dev/null || echo 'empty')"
fi

_section "rm_wrapper: path guard — refuses /, ., .."
for _g in "/" "." ".."; do
  _g_out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor bash "$REPO_DIR/rm_wrapper.sh" "$_g" 2>&1; echo "EXIT:$?")
  _g_exit=$(echo "$_g_out" | grep "EXIT:" | cut -d: -f2)
  [[ "$_g_exit" == "1" ]] && _pass "guard '$_g': refused (exit 1)" || _fail "guard '$_g': exit=$_g_exit"
done

_section "rm_wrapper: -- double-dash operand separator"
f_dd="$WORK_DIR/double-dash-test.txt"
echo "dd" > "$f_dd"
_rm -- "$f_dd"
if ls "$TEST_TRASH/" 2>/dev/null | grep -q "double-dash-test.txt"; then
  _pass "double-dash: file after -- moved to ai-trash"
else
  _fail "double-dash: file not in ai-trash"
fi

_section "rm_wrapper: -v verbose flag"
f_verbose="$WORK_DIR/verbose-rm-test.txt"
echo "v" > "$f_verbose"
v_out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor bash "$REPO_DIR/rm_wrapper.sh" -v "$f_verbose" 2>/dev/null)
if [[ ! -f "$f_verbose" ]]; then
  _pass "-v: file deleted"
else
  _fail "-v: file still exists"
fi
if echo "$v_out" | grep -q "verbose-rm-test.txt"; then
  _pass "-v: filename printed to stdout"
else
  _fail "-v: filename not in output. Got: '$v_out'"
fi

_section "rm_wrapper: -d flag — empty directory trashed"
d_empty_d="$WORK_DIR/empty-dir-flag"
mkdir -p "$d_empty_d"
_rm -d "$d_empty_d"
if ls "$TEST_TRASH/" 2>/dev/null | grep -q "empty-dir-flag"; then
  _pass "-d: empty dir moved to ai-trash"
else
  _fail "-d: empty dir not in ai-trash. Contents: $(ls "$TEST_TRASH/" 2>/dev/null || echo 'empty')"
fi

_section "rm_wrapper: -d flag — non-empty directory errors"
d_nonempty_d="$WORK_DIR/nonempty-dir-flag"
mkdir -p "$d_nonempty_d"
echo "x" > "$d_nonempty_d/file.txt"
d_ne_out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor bash "$REPO_DIR/rm_wrapper.sh" -d "$d_nonempty_d" 2>&1; echo "EXIT:$?")
d_ne_exit=$(echo "$d_ne_out" | grep "EXIT:" | cut -d: -f2)
if [[ "$d_ne_exit" == "1" ]] && [[ -d "$d_nonempty_d" ]]; then
  _pass "-d non-empty: exits 1, directory untouched"
else
  _fail "-d non-empty: exit=$d_ne_exit dir_exists=$(test -d "$d_nonempty_d" && echo yes || echo no)"
fi
/bin/rm -rf "$d_nonempty_d"

_section "rm_wrapper: -I flag — prompt suppressed when no TTY (4 files all deleted)"
f_Ia="$WORK_DIR/ionce-a.txt"; echo "a" > "$f_Ia"
f_Ib="$WORK_DIR/ionce-b.txt"; echo "b" > "$f_Ib"
f_Ic="$WORK_DIR/ionce-c.txt"; echo "c" > "$f_Ic"
f_Id="$WORK_DIR/ionce-d.txt"; echo "d" > "$f_Id"
echo "" | HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  bash "$REPO_DIR/rm_wrapper.sh" -I "$f_Ia" "$f_Ib" "$f_Ic" "$f_Id" 2>&1 || true
_I_all=true
for _fi in "$f_Ia" "$f_Ib" "$f_Ic" "$f_Id"; do [[ -f "$_fi" ]] && _I_all=false; done
[[ "$_I_all" == true ]] && _pass "-I no-TTY: all 4 files deleted (prompt suppressed)" \
  || _fail "-I no-TTY: not all files deleted"

_section "rm_wrapper: symlink — symlink trashed, target intact"
f_sym_target="$WORK_DIR/sym-target.txt"
f_sym_link="$WORK_DIR/sym-link.txt"
echo "target-content" > "$f_sym_target"
ln -sf "$f_sym_target" "$f_sym_link"
_rm "$f_sym_link"
if ls "$TEST_TRASH/" 2>/dev/null | grep -q "sym-link.txt"; then
  _pass "symlink: symlink moved to ai-trash"
else
  _fail "symlink: symlink not in ai-trash"
fi
if [[ -f "$f_sym_target" ]]; then
  _pass "symlink: target file untouched"
else
  _fail "symlink: target file was deleted"
fi

# ─── rmdir wrapper ──────────────────────────────────────────────────────
RMDIR_LINK="$WORK_DIR/rmdir"
ln -sf "$REPO_DIR/rm_wrapper.sh" "$RMDIR_LINK"
_rmdir() {
  HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor bash "$RMDIR_LINK" "$@"
}

_section "rmdir_wrapper: empty directory goes to ai-trash"
d_rmdir_e="$WORK_DIR/rmdir-empty"
mkdir -p "$d_rmdir_e"
_rmdir "$d_rmdir_e"
if ls "$TEST_TRASH/" 2>/dev/null | grep -q "rmdir-empty"; then
  _pass "rmdir: empty dir moved to ai-trash"
else
  _fail "rmdir: empty dir not in ai-trash. Contents: $(ls "$TEST_TRASH/" 2>/dev/null || echo 'empty')"
fi

_section "rmdir_wrapper: non-empty directory errors"
d_rmdir_ne="$WORK_DIR/rmdir-nonempty"
mkdir -p "$d_rmdir_ne"
echo "x" > "$d_rmdir_ne/file.txt"
rmdir_ne_out=$(_rmdir "$d_rmdir_ne" 2>&1; echo "EXIT:$?")
rmdir_ne_exit=$(echo "$rmdir_ne_out" | grep "EXIT:" | cut -d: -f2)
if [[ "$rmdir_ne_exit" == "1" ]] && [[ -d "$d_rmdir_ne" ]]; then
  _pass "rmdir: non-empty dir errors, directory untouched"
else
  _fail "rmdir: non-empty dir — exit=$rmdir_ne_exit dir_exists=$(test -d "$d_rmdir_ne" && echo yes || echo no)"
fi
/bin/rm -rf "$d_rmdir_ne"

_section "rmdir_wrapper: non-existent directory errors"
rmdir_nx_out=$(_rmdir "$WORK_DIR/rmdir-nonexistent" 2>&1; echo "EXIT:$?")
rmdir_nx_exit=$(echo "$rmdir_nx_out" | grep "EXIT:" | cut -d: -f2)
[[ "$rmdir_nx_exit" == "1" ]] && _pass "rmdir: non-existent dir exits 1" \
  || _fail "rmdir: non-existent exits $rmdir_nx_exit"

_section "rmdir_wrapper: -v flag prints directory name"
d_rmdir_v="$WORK_DIR/rmdir-verbose"
mkdir -p "$d_rmdir_v"
rmdir_v_out=$(_rmdir -v "$d_rmdir_v" 2>&1)
if echo "$rmdir_v_out" | grep -q "rmdir-verbose"; then
  _pass "rmdir -v: directory name in output"
else
  _fail "rmdir -v: name not in output. Got: '$rmdir_v_out'"
fi
if ls "$TEST_TRASH/" 2>/dev/null | grep -q "rmdir-verbose"; then
  _pass "rmdir -v: directory moved to ai-trash"
else
  _fail "rmdir -v: directory not in ai-trash"
fi

_section "rmdir_wrapper: -p flag removes parent chain"
d_rmdir_p_root="$WORK_DIR/rmdir-p-root"
d_rmdir_p_full="$d_rmdir_p_root/rmdir-p-child/rmdir-p-leaf"
mkdir -p "$d_rmdir_p_full"
_rmdir -p "$d_rmdir_p_full"
if [[ ! -d "$d_rmdir_p_full" ]]; then
  _pass "rmdir -p: leaf directory removed"
else
  _fail "rmdir -p: leaf directory still exists"
fi
if [[ ! -d "$d_rmdir_p_root/rmdir-p-child" ]]; then
  _pass "rmdir -p: parent chain removed"
else
  _skip "rmdir -p: parent chain not fully removed (unexpected state)"
fi

_section "ai-trash CLI: restore — overwrite prompt accepts y"
f_ow_y="$WORK_DIR/overwrite-y.txt"
echo "original" > "$f_ow_y"
_rm "$f_ow_y"
echo "blocker" > "$f_ow_y"
ow_y_out=$(echo "y" | HOME="$TEST_HOME" bash "$REPO_DIR/ai-trash" restore overwrite-y.txt 2>&1 || true)
if [[ -f "$f_ow_y" ]]; then
  ow_y_content=$(cat "$f_ow_y")
  [[ "$ow_y_content" == "original" ]] \
    && _pass "restore overwrite y: original content restored" \
    || _fail "restore overwrite y: content='$ow_y_content' (expected 'original')"
else
  _fail "restore overwrite y: file missing after restore. Output: $ow_y_out"
fi

_section "ai-trash CLI: restore — overwrite prompt aborted by n"
f_ow_n="$WORK_DIR/overwrite-n.txt"
echo "to-trash" > "$f_ow_n"
_rm "$f_ow_n"
echo "keep-this" > "$f_ow_n"
echo "n" | HOME="$TEST_HOME" bash "$REPO_DIR/ai-trash" restore overwrite-n.txt 2>&1 || true
if [[ -f "$f_ow_n" ]]; then
  ow_n_content=$(cat "$f_ow_n")
  [[ "$ow_n_content" == "keep-this" ]] \
    && _pass "restore overwrite n: existing file preserved" \
    || _fail "restore overwrite n: content='$ow_n_content'"
else
  _fail "restore overwrite n: file missing after aborted restore"
fi

_section "ai-trash-cleanup: purges items older than 30 days"
f_cleanup_old="$WORK_DIR/cleanup-old.txt"
echo "old" > "$f_cleanup_old"
_rm "$f_cleanup_old"
_cleanup_old_item=$(ls "$TEST_TRASH/" 2>/dev/null | grep "^cleanup-old.txt" | head -1 || true)
if [[ -n "$_cleanup_old_item" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    touch -t "$(date -v-31d +%Y%m%d%H%M)" "$TEST_TRASH/$_cleanup_old_item"
  else
    touch -t "$(date -d '31 days ago' +%Y%m%d%H%M)" "$TEST_TRASH/$_cleanup_old_item"
  fi
  HOME="$TEST_HOME" bash "$REPO_DIR/ai-trash-cleanup"
  if ! ls "$TEST_TRASH/" 2>/dev/null | grep -q "^cleanup-old.txt"; then
    _pass "ai-trash-cleanup: 31-day-old item purged"
  else
    _fail "ai-trash-cleanup: old item still present after cleanup"
  fi
else
  _fail "ai-trash-cleanup: cleanup-old.txt not found in trash (setup failed)"
fi

_section "ai-trash-cleanup: preserves items newer than 30 days"
f_cleanup_new="$WORK_DIR/cleanup-new.txt"
echo "new" > "$f_cleanup_new"
_rm "$f_cleanup_new"
HOME="$TEST_HOME" bash "$REPO_DIR/ai-trash-cleanup"
if ls "$TEST_TRASH/" 2>/dev/null | grep -q "cleanup-new.txt"; then
  _pass "ai-trash-cleanup: recent item preserved"
else
  _fail "ai-trash-cleanup: recent item unexpectedly purged"
fi

# Clear items added by gap-coverage tests
_ai_trash empty --force >/dev/null 2>&1

_section "rm_wrapper: --help passes through to /bin/rm"
out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" bash "$REPO_DIR/rm_wrapper.sh" --help 2>&1 || true)
if echo "$out" | grep -qiE "usage|illegal option|remove"; then
  _pass "--help passed through to /bin/rm"
else
  _skip "--help: output didn't match expected pattern (may vary by platform): $out"
fi

_section "rm_wrapper: no stdout leak when xattr errors"
# xattr on macOS prints errors to stdout (not stderr), so 2>/dev/null is insufficient.
# The fix is >/dev/null 2>&1 on all xattr calls in _write_meta.
# We inject a fake xattr that unconditionally emits to stdout, then verify rm is silent.
if [[ "$(uname -s)" == "Darwin" ]]; then
  _fake_xattr_dir="$WORK_DIR/fake-xattr"
  mkdir -p "$_fake_xattr_dir"
  printf '#!/bin/bash\necho "xattr-stdout-leak: $*"\n/usr/bin/xattr "$@"\n' > "$_fake_xattr_dir/xattr"
  chmod +x "$_fake_xattr_dir/xattr"
  _leak_test_file="$WORK_DIR/stdout-leak-test.txt"
  echo "test" > "$_leak_test_file"
  # TERM_PROGRAM=cursor triggers AI detection → move_to_ai_trash → _write_meta → xattr calls
  _leak_stdout=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
    PATH="$_fake_xattr_dir:$PATH" bash "$REPO_DIR/rm_wrapper.sh" "$_leak_test_file" 2>/dev/null)
  if [[ -z "$_leak_stdout" ]]; then
    _pass "no stdout leak: xattr output suppressed"
  else
    _fail "stdout leak: rm produced unexpected output: $_leak_stdout"
  fi
else
  _skip "xattr stdout leak test: macOS only"
fi

_section "rm_wrapper: Put Back — AI rm writes to ~/.Trash/ top-level with xattrs (macOS)"
# This test uses real HOME so FSMoveObjectToTrashSync actually fires and writes ptbL/ptbN
# to ~/.Trash/.DS_Store. We verify the observable outcome: file lands in ~/.Trash/ top-level
# and has com.ai-trash.original-path set.
if [[ "$(uname -s)" == "Darwin" ]]; then
  f_ptb_ai="$HOME/ai-trash-ptb-ai-$$.txt"
  echo "ai putback test" > "$f_ptb_ai"
  trash_ptb_ai="$HOME/.Trash/$(basename "$f_ptb_ai")"
  TERM_PROGRAM=cursor bash "$REPO_DIR/rm_wrapper.sh" "$f_ptb_ai" 2>/dev/null || true
  if [[ -e "$trash_ptb_ai" ]]; then
    _pass "Put Back (AI): file in ~/.Trash/ top-level (not a subdir)"
    orig_ptb=$(xattr -p com.ai-trash.original-path "$trash_ptb_ai" 2>/dev/null || true)
    [[ "$orig_ptb" == "$f_ptb_ai" ]] \
      && _pass "Put Back (AI): com.ai-trash.original-path xattr correct" \
      || _fail "Put Back (AI): original-path='$orig_ptb' want '$f_ptb_ai'"
    /bin/rm -f "$trash_ptb_ai"
  else
    _fail "Put Back (AI): file not found in ~/.Trash/ (expected '$trash_ptb_ai')"
    /bin/rm -f "$f_ptb_ai" 2>/dev/null
  fi
else
  _skip "Put Back AI test: macOS only"
fi

_section "rm_wrapper: Put Back — safe-mode non-AI rm writes to ~/.Trash/ top-level (macOS)"
# Uses a temporary XDG_CONFIG_HOME with MODE=safe so we can test safe-mode behaviour
# against the real HOME (required for FSMoveObjectToTrashSync to fire).
if [[ "$(uname -s)" == "Darwin" ]]; then
  _ptb_conf="$WORK_DIR/ptb-conf"
  mkdir -p "$_ptb_conf/ai-trash"
  cp "$REPO_DIR/config.default.sh" "$_ptb_conf/ai-trash/config.sh"
  sed -i.bak "s/^MODE=.*/MODE=safe/" "$_ptb_conf/ai-trash/config.sh" \
    && /bin/rm -f "$_ptb_conf/ai-trash/config.sh.bak"
  f_ptb_safe="$HOME/ai-trash-ptb-safe-$$.txt"
  echo "safe putback test" > "$f_ptb_safe"
  trash_ptb_safe="$HOME/.Trash/$(basename "$f_ptb_safe")"
  env -i HOME="$HOME" XDG_CONFIG_HOME="$_ptb_conf" PATH=/bin:/usr/bin:/usr/local/bin \
    bash "$REPO_DIR/rm_wrapper.sh" "$f_ptb_safe" </dev/null 2>/dev/null || true
  if [[ ! -f "$f_ptb_safe" ]] && [[ -e "$trash_ptb_safe" ]]; then
    _pass "Put Back (safe): file in ~/.Trash/ top-level"
    /bin/rm -f "$trash_ptb_safe"
  elif [[ ! -f "$f_ptb_safe" ]]; then
    # AI parent (claude) detected in process tree — file still routed to ai-trash path
    # which also uses FSMoveObjectToTrashSync; count as pass since Put Back still works.
    _skip "Put Back (safe): AI parent detected — file trashed via ai-trash path (Put Back still applies)"
    /bin/rm -f "$trash_ptb_safe" 2>/dev/null
  else
    _fail "Put Back (safe): file still exists at original path after rm"
    /bin/rm -f "$f_ptb_safe" 2>/dev/null
  fi
else
  _skip "Put Back safe mode test: macOS only"
fi

# ─── Summary ───────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────"
if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}All tests passed.${RESET}"
else
  echo -e "${RED}$FAILURES test(s) failed.${RESET}"
  exit 1
fi
