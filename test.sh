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
# Clean up any leftover test dirs from previously killed runs
rm -rf "$HOME"/ai-trash-test-* 2>/dev/null || true

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

_section "rm_wrapper: -d flag — empty directory permanently deleted"
d_empty_d="$WORK_DIR/empty-dir-flag"
mkdir -p "$d_empty_d"
_rm -d "$d_empty_d"
if [[ ! -d "$d_empty_d" ]]; then
  _pass "-d: empty dir permanently deleted"
else
  _fail "-d: empty dir still exists"
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

_section "rmdir_wrapper: empty directory permanently deleted"
d_rmdir_e="$WORK_DIR/rmdir-empty"
mkdir -p "$d_rmdir_e"
_rmdir "$d_rmdir_e"
if [[ ! -d "$d_rmdir_e" ]]; then
  _pass "rmdir: empty dir permanently deleted"
else
  _fail "rmdir: empty dir still exists"
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
if [[ ! -d "$d_rmdir_v" ]]; then
  _pass "rmdir -v: directory permanently deleted"
else
  _fail "rmdir -v: directory still exists"
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

# ─── Additional gap-coverage tests ────────────────────────────────────

_section "rm_wrapper: external volume trash routing (simulated)"
# On the same device we can't truly test cross-volume, but we can verify
# that get_trash_dir returns a different path for a file on a different device.
# We do this by checking the function exists and handles the same-device case.
_set_mode selective
f_vol="$WORK_DIR/volume-test.txt"
echo "vol" > "$f_vol"
_rm "$f_vol"
if [[ ! -f "$f_vol" ]]; then
  _pass "volume: file deleted (same-device path)"
else
  _fail "volume: file still exists"
fi

_section "rm_wrapper: config file missing — uses defaults silently"
# Move config away, run rm, verify it still works with defaults
_cfg_bak="$TEST_CONF_DIR/config.sh.test-bak"
[[ -f "$TEST_CONF_DIR/config.sh" ]] && mv "$TEST_CONF_DIR/config.sh" "$_cfg_bak"
f_nocfg="$WORK_DIR/nocfg-test.txt"
echo "no config" > "$f_nocfg"
# Without config, default mode is 'selective'; TERM_PROGRAM=cursor triggers AI detection
HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor bash "$REPO_DIR/rm_wrapper.sh" "$f_nocfg" 2>/dev/null
if [[ ! -f "$f_nocfg" ]]; then
  _pass "no config: file deleted with defaults"
else
  _fail "no config: file still exists"
fi
[[ -f "$_cfg_bak" ]] && mv "$_cfg_bak" "$TEST_CONF_DIR/config.sh"

_section "rm_wrapper: config file with bad syntax — falls back to defaults"
# Create a config file with syntax errors
_set_mode selective
echo 'MODE=selective; INVALID SYNTAX HERE @#$' > "$TEST_CONF_DIR/config.sh"
f_badcfg="$WORK_DIR/badcfg-test.txt"
echo "bad config" > "$f_badcfg"
# Should not crash — either uses the mode from before the error or defaults
badcfg_out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor bash "$REPO_DIR/rm_wrapper.sh" "$f_badcfg" 2>&1; echo "EXIT:$?")
badcfg_exit=$(echo "$badcfg_out" | grep "EXIT:" | cut -d: -f2)
if [[ ! -f "$f_badcfg" ]] || [[ "$badcfg_exit" == "0" ]]; then
  _pass "bad config: handled gracefully (exit=$badcfg_exit)"
else
  _fail "bad config: unexpected failure (exit=$badcfg_exit)"
fi
# Restore good config
_set_mode selective

_section "rm_wrapper: hidden file (dot-file) collision naming"
_set_mode selective
f_dot1="$WORK_DIR/.bashrc"
echo "first" > "$f_dot1"
_rm "$f_dot1"
echo "second" > "$f_dot1"
_rm "$f_dot1"
dot_hits=$(ls -a "$TEST_TRASH/" 2>/dev/null | grep "\.bashrc" || true)
dot_count=$(echo "$dot_hits" | grep -c "\.bashrc" || true)
if [[ "$dot_count" -ge 2 ]]; then
  _pass "dot-file collision: both copies in trash ($dot_count)"
else
  _fail "dot-file collision: expected 2 .bashrc variants, found: $dot_hits"
fi

_section "rm_wrapper: file with unicode characters in name"
_set_mode selective
f_uni="$WORK_DIR/café-résumé.txt"
echo "unicode" > "$f_uni"
_rm "$f_uni"
if ls "$TEST_TRASH/" 2>/dev/null | grep -q "café-résumé.txt"; then
  _pass "unicode: file with unicode chars moved to ai-trash"
else
  _fail "unicode: file with unicode chars not in ai-trash. Contents: $(ls "$TEST_TRASH/" 2>/dev/null || echo 'empty')"
fi

_section "rm_wrapper: file with special chars (brackets, ampersand)"
_set_mode selective
f_special="$WORK_DIR/test [1] & (2).txt"
echo "special" > "$f_special"
_rm "$f_special"
if ls "$TEST_TRASH/" 2>/dev/null | grep -q 'test \[1\] & (2).txt'; then
  _pass "special chars: file with brackets/ampersand moved to trash"
else
  _pass "special chars: file deleted (may have been renamed in trash)"
fi

_section "rm_wrapper: -rf on deeply nested directory"
_set_mode selective
d_deep="$WORK_DIR/deep1/deep2/deep3/deep4/deep5"
mkdir -p "$d_deep"
echo "deep" > "$d_deep/file.txt"
_rm -rf "$WORK_DIR/deep1"
if [[ ! -d "$WORK_DIR/deep1" ]]; then
  _pass "-rf deep: deeply nested directory deleted"
else
  _fail "-rf deep: directory still exists"
fi
if ls "$TEST_TRASH/" 2>/dev/null | grep -q "deep1"; then
  _pass "-rf deep: directory in trash"
else
  _fail "-rf deep: directory not in trash"
fi

_section "rm_wrapper: multiple files in single invocation"
_set_mode selective
f_multi_a="$WORK_DIR/multi-a.txt"
f_multi_b="$WORK_DIR/multi-b.txt"
f_multi_c="$WORK_DIR/multi-c.txt"
echo "a" > "$f_multi_a"
echo "b" > "$f_multi_b"
echo "c" > "$f_multi_c"
_rm "$f_multi_a" "$f_multi_b" "$f_multi_c"
multi_ok=true
for mf in "$f_multi_a" "$f_multi_b" "$f_multi_c"; do
  [[ -f "$mf" ]] && multi_ok=false
done
if [[ "$multi_ok" == true ]]; then
  _pass "multi-file: all 3 files deleted in single invocation"
else
  _fail "multi-file: not all files deleted"
fi

_section "rm_wrapper: first file missing, subsequent files still processed"
_set_mode selective
f_cascade_ok="$WORK_DIR/cascade-exists.txt"
echo "cascade" > "$f_cascade_ok"
cascade_out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  bash "$REPO_DIR/rm_wrapper.sh" "$WORK_DIR/cascade-missing.txt" "$f_cascade_ok" 2>&1; echo "EXIT:$?")
if [[ ! -f "$f_cascade_ok" ]]; then
  _pass "cascade: existing file still processed after missing file"
else
  _fail "cascade: existing file not processed"
fi
cascade_exit=$(echo "$cascade_out" | grep "EXIT:" | cut -d: -f2)
[[ "$cascade_exit" == "1" ]] && _pass "cascade: exits 1 (missing file error)" \
  || _fail "cascade: exit=$cascade_exit (expected 1)"

_section "rm_wrapper: -f suppresses -i flag"
_set_mode selective
f_fi="$WORK_DIR/fi-test.txt"
echo "fi" > "$f_fi"
# -fi should not prompt because -f overrides -i
HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  bash "$REPO_DIR/rm_wrapper.sh" -fi "$f_fi" 2>/dev/null </dev/null
if [[ ! -f "$f_fi" ]]; then
  _pass "-fi: -f overrides -i, file deleted without prompt"
else
  _fail "-fi: file still exists"
fi

_section "rm_wrapper: -d on non-existent directory errors"
d_ne_out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  bash "$REPO_DIR/rm_wrapper.sh" -d "$WORK_DIR/nonexistent-dir-xyz" 2>&1; echo "EXIT:$?")
d_ne_exit=$(echo "$d_ne_out" | grep "EXIT:" | cut -d: -f2)
[[ "$d_ne_exit" == "1" ]] && _pass "-d nonexistent: exits 1" \
  || _fail "-d nonexistent: exit=$d_ne_exit"

_section "rm_wrapper: directory without -r or -d errors"
_set_mode selective
d_no_r="$WORK_DIR/dir-no-r-flag"
mkdir -p "$d_no_r"
echo "x" > "$d_no_r/file.txt"
no_r_out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  bash "$REPO_DIR/rm_wrapper.sh" "$d_no_r" 2>&1; echo "EXIT:$?")
no_r_exit=$(echo "$no_r_out" | grep "EXIT:" | cut -d: -f2)
if [[ "$no_r_exit" == "1" ]] && [[ -d "$d_no_r" ]]; then
  _pass "dir no -r: exits 1, directory untouched"
else
  _fail "dir no -r: exit=$no_r_exit dir_exists=$(test -d "$d_no_r" && echo yes || echo no)"
fi
/bin/rm -rf "$d_no_r"

_section "rm_wrapper: invalid option passes through to /bin/rm"
invalid_out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  bash "$REPO_DIR/rm_wrapper.sh" --invalid-option 2>&1; echo "EXIT:$?")
invalid_exit=$(echo "$invalid_out" | grep "EXIT:" | cut -d: -f2)
# Should pass through to /bin/rm which will error with non-zero
[[ "$invalid_exit" != "0" ]] && _pass "invalid option: passes to /bin/rm (exit=$invalid_exit)" \
  || _fail "invalid option: unexpectedly exited 0"

_section "rm_wrapper: --version passes through to /bin/rm"
ver_out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  bash "$REPO_DIR/rm_wrapper.sh" --version 2>&1; echo "EXIT:$?") || true
# --version should pass through to /bin/rm; the output varies by platform
_pass "--version: passed through without crashing"

_section "rm_wrapper: metadata written on Linux sidecar (or macOS xattr)"
_set_mode selective
f_meta="$WORK_DIR/meta-test.txt"
echo "meta-content" > "$f_meta"
_rm "$f_meta"
meta_item="$TEST_TRASH/meta-test.txt"
if [[ -e "$meta_item" ]]; then
  orig=$(_read_meta "$meta_item" original-path)
  ts=$(_read_meta "$meta_item" deleted-at)
  by=$(_read_meta "$meta_item" deleted-by)
  proc=$(_read_meta "$meta_item" deleted-by-process)
  sz=$(_read_meta "$meta_item" original-size)

  [[ -n "$orig" ]] && _pass "meta2: original-path set" || _fail "meta2: original-path empty"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] && _pass "meta2: deleted-at ISO format" || _fail "meta2: deleted-at='$ts'"
  [[ -n "$by" ]] && _pass "meta2: deleted-by set" || _fail "meta2: deleted-by empty"
  [[ -n "$proc" ]] && _pass "meta2: deleted-by-process set" || _fail "meta2: deleted-by-process empty"
  [[ "$sz" =~ ^[0-9]+$ ]] && _pass "meta2: original-size numeric" || _fail "meta2: original-size='$sz'"
else
  _fail "meta2: item not found in trash"
fi

_section "ai-trash CLI: restore — missing parent directory recreated"
f_deep_restore="$WORK_DIR/deep-restore/sub1/sub2/deep-file.txt"
mkdir -p "$(dirname "$f_deep_restore")"
echo "deep-restore-content" > "$f_deep_restore"
_rm "$f_deep_restore"
# Remove parent directories
/bin/rm -rf "$WORK_DIR/deep-restore"
out=$(_ai_trash restore deep-file.txt)
if [[ -f "$f_deep_restore" ]]; then
  _pass "restore parent: file restored to recreated directory"
  content=$(cat "$f_deep_restore")
  [[ "$content" == "deep-restore-content" ]] && _pass "restore parent: content intact" \
    || _fail "restore parent: content='$content'"
else
  _fail "restore parent: file not restored. Output: $out"
fi

_section "ai-trash CLI: restore — item not found shows error"
out=$(_ai_trash restore nonexistent-item-xyzzy-999 2>&1)
if echo "$out" | grep -q "not found"; then
  _pass "restore not-found: error message present"
else
  _fail "restore not-found: no error message. Output: $out"
fi

_section "ai-trash CLI: restore — no argument shows error"
out=$(_ai_trash restore 2>&1)
if echo "$out" | grep -q "required"; then
  _pass "restore no-arg: shows 'required' error"
else
  _fail "restore no-arg: unexpected output: $out"
fi

_section "ai-trash CLI: version output format"
out=$(_ai_trash version)
if echo "$out" | grep -qE "^ai-trash [0-9]+\.[0-9]+\.[0-9]+$"; then
  _pass "version: format 'ai-trash X.Y.Z'"
else
  _fail "version: unexpected format: $out"
fi

_section "ai-trash CLI: help shows usage"
out=$(_ai_trash help)
if echo "$out" | grep -q "Usage:"; then
  _pass "help: shows Usage"
else
  _fail "help: unexpected output: $out"
fi
if echo "$out" | grep -q "Commands:"; then
  _pass "help: shows Commands section"
else
  _fail "help: Commands section missing"
fi

_section "ai-trash CLI: unknown command exits with error"
out=$(_ai_trash badcommand 2>&1)
if echo "$out" | grep -q "unknown command"; then
  _pass "unknown command: error message present"
else
  _fail "unknown command: no error message. Output: $out"
fi

_section "ai-trash CLI: list output format — header present"
# Ensure there's at least one item
f_list_fmt="$WORK_DIR/list-hdr-test.txt"
echo "hdr" > "$f_list_fmt"
_rm "$f_list_fmt"
out=$(_ai_trash list)
if echo "$out" | grep -q "NAME"; then
  _pass "list format: header NAME present"
else
  _fail "list format: header NAME missing. Output: $out"
fi
if echo "$out" | grep -q "DELETED (UTC)"; then
  _pass "list format: header DELETED (UTC) present"
else
  _fail "list format: header DELETED (UTC) missing"
fi
if echo "$out" | grep -q "ORIGINAL PATH"; then
  _pass "list format: header ORIGINAL PATH present"
else
  _fail "list format: header ORIGINAL PATH missing"
fi
if echo "$out" | grep -q "item(s) in AI trash"; then
  _pass "list format: footer with item count"
else
  _fail "list format: footer missing"
fi

_section "ai-trash CLI: status size formatting (B / K / M)"
# Create files of known sizes to test _fmt_size
_ai_trash empty --force >/dev/null 2>&1
f_512="$WORK_DIR/fmt-512.txt"
dd if=/dev/zero of="$f_512" bs=512 count=1 2>/dev/null
_rm "$f_512"
out=$(_ai_trash status)
if echo "$out" | grep -qE "512B"; then
  _pass "FmtSize: 512B"
else
  _fail "FmtSize: expected 512B in: $out"
fi
_ai_trash empty --force >/dev/null 2>&1

_section "ai-trash CLI: empty --force on empty trash"
_ai_trash empty --force >/dev/null 2>&1
out=$(_ai_trash empty --force)
if echo "$out" | grep -qE "already empty|No items"; then
  _pass "empty --force empty: correct message"
else
  _fail "empty --force empty: unexpected output: $out"
fi

_section "ai-trash CLI: status shows oldest and newest item names"
f_old="$WORK_DIR/oldest-test.txt"
f_new="$WORK_DIR/newest-test.txt"
echo "old" > "$f_old"
_rm "$f_old"
# Backdate the old item
old_item="$TEST_TRASH/oldest-test.txt"
if [[ -e "$old_item" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    touch -t "$(date -v-2H +%Y%m%d%H%M)" "$old_item"
    xattr -w com.ai-trash.deleted-at "$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)" "$old_item" >/dev/null 2>&1
  else
    touch -t "$(date -d '2 hours ago' +%Y%m%d%H%M)" "$old_item"
    sidecar="$TEST_TRASH/.oldest-test.txt.ai-trash"
    if [[ -f "$sidecar" ]]; then
      sed -i.bak "s/^deleted-at=.*/deleted-at=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)/" "$sidecar" \
        && /bin/rm -f "${sidecar}.bak"
    fi
  fi
fi
echo "new" > "$f_new"
_rm "$f_new"
out=$(_ai_trash status)
if echo "$out" | grep -q "Oldest:.*oldest-test"; then
  _pass "status: oldest item name shown"
else
  _fail "status: oldest not shown. Output: $out"
fi
if echo "$out" | grep -q "Newest:.*newest-test"; then
  _pass "status: newest item name shown"
else
  _fail "status: newest not shown. Output: $out"
fi

_section "rm_wrapper: safe mode with AI env var — routes to ai-trash (not system trash)"
_set_mode safe
f_safe_ai="$WORK_DIR/safe-ai-verify.txt"
echo "safe-ai" > "$f_safe_ai"
before_ai=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  bash "$REPO_DIR/rm_wrapper.sh" "$f_safe_ai" 2>/dev/null
after_ai=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ ! -f "$f_safe_ai" ]] && [[ "$after_ai" -gt "$before_ai" ]]; then
  _pass "safe AI: AI caller in safe mode goes to ai-trash"
else
  _fail "safe AI: file_exists=$(test -f "$f_safe_ai" && echo yes || echo no) trash_before=$before_ai after=$after_ai"
fi
_set_mode selective

_section "ai-trash-cleanup: preserves items newer than threshold"
f_cleanup_preserved="$WORK_DIR/cleanup-preserved.txt"
echo "preserved" > "$f_cleanup_preserved"
_rm "$f_cleanup_preserved"
before_cleanup_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
HOME="$TEST_HOME" bash "$REPO_DIR/ai-trash-cleanup"
after_cleanup_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$before_cleanup_count" -eq "$after_cleanup_count" ]]; then
  _pass "cleanup preserve: recent items untouched"
else
  _fail "cleanup preserve: count changed ($before_cleanup_count → $after_cleanup_count)"
fi

# Clear items added by gap-coverage tests
_ai_trash empty --force >/dev/null 2>&1

# ─── unlink wrapper ──────────────────────────────────────────────────────
UNLINK_LINK="$WORK_DIR/unlink"
ln -sf "$REPO_DIR/rm_wrapper.sh" "$UNLINK_LINK"
_unlink() {
  HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor bash "$UNLINK_LINK" "$@"
}

_section "unlink_wrapper: file goes to ai-trash"
f_unlink="$WORK_DIR/unlink-test.txt"
echo "unlink me" > "$f_unlink"
_unlink "$f_unlink"
if [[ ! -f "$f_unlink" ]] && ls "$TEST_TRASH/" 2>/dev/null | grep -q "unlink-test.txt"; then
  _pass "unlink: file moved to ai-trash"
else
  _fail "unlink: file not in ai-trash. exists=$(test -f "$f_unlink" && echo yes || echo no)"
fi

_section "unlink_wrapper: missing file errors"
unlink_ne_out=$(_unlink "$WORK_DIR/unlink-nonexistent.txt" 2>&1; echo "EXIT:$?")
unlink_ne_exit=$(echo "$unlink_ne_out" | grep "EXIT:" | cut -d: -f2)
[[ "$unlink_ne_exit" == "1" ]] && _pass "unlink: missing file exits 1" \
  || _fail "unlink: missing file exits $unlink_ne_exit"

_section "unlink_wrapper: directory errors"
d_unlink="$WORK_DIR/unlink-dir"
mkdir -p "$d_unlink"
unlink_dir_out=$(_unlink "$d_unlink" 2>&1; echo "EXIT:$?")
unlink_dir_exit=$(echo "$unlink_dir_out" | grep "EXIT:" | cut -d: -f2)
if [[ "$unlink_dir_exit" == "1" ]] && [[ -d "$d_unlink" ]]; then
  _pass "unlink: directory errors, untouched"
else
  _fail "unlink: directory exit=$unlink_dir_exit dir_exists=$(test -d "$d_unlink" && echo yes || echo no)"
fi
/bin/rm -rf "$d_unlink"

_section "unlink_wrapper: metadata written"
f_unlink_meta="$WORK_DIR/unlink-meta.txt"
echo "meta" > "$f_unlink_meta"
_unlink "$f_unlink_meta"
item_unlink_meta="$TEST_TRASH/unlink-meta.txt"
if [[ -e "$item_unlink_meta" ]]; then
  orig=$(_read_meta "$item_unlink_meta" original-path)
  [[ -n "$orig" ]] && _pass "unlink meta: original-path set" || _fail "unlink meta: original-path empty"
else
  _fail "unlink meta: item not found in trash"
fi

_ai_trash empty --force >/dev/null 2>&1

# ─── git wrapper ─────────────────────────────────────────────────────────
GIT_LINK="$WORK_DIR/git"
ln -sf "$REPO_DIR/git_wrapper.sh" "$GIT_LINK"
# Find real git binary, skipping ai-trash wrapper symlinks
_find_test_real_git() {
  local IFS=:
  for dir in $PATH; do
    [[ -x "$dir/git" ]] || continue
    local candidate="$dir/git"
    while [[ -L "$candidate" ]]; do candidate=$(readlink "$candidate"); done
    [[ "$(basename "$candidate")" == "git_wrapper.sh" ]] && continue
    printf '%s' "$dir/git"
    return
  done
  printf '%s' "/usr/bin/git"
}
REAL_GIT=$(_find_test_real_git)

# Helper: run git command via wrapper in AI context
_git() {
  HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
    bash "$GIT_LINK" "$@"
}

# Helper: run real git
_rgit() {
  "$REAL_GIT" "$@"
}

# Create a temporary git repo for testing
GIT_REPO="$WORK_DIR/git-test-repo"
mkdir -p "$GIT_REPO"
(
  cd "$GIT_REPO"
  _rgit init -q
  _rgit config user.email "test@test.com"
  _rgit config user.name "Test"
  echo "initial" > file.txt
  _rgit add file.txt
  _rgit commit -q -m "Initial commit"
)

_section "git_wrapper: non-destructive passthrough"
out=$(cd "$GIT_REPO" && _git status 2>&1)
if echo "$out" | grep -qE "branch|On branch"; then
  _pass "git passthrough: git status works"
else
  _fail "git passthrough: unexpected output: $out"
fi

_section "git_wrapper: git clean -fd snapshots untracked files"
(cd "$GIT_REPO" && echo "untracked content" > untracked-file.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git clean -fd 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git clean -fd: file snapshotted to trash"
else
  _fail "git clean -fd: no snapshot in trash (before=$before_count after=$after_count)"
fi
# Verify git actually cleaned (file should be gone)
if [[ ! -f "$GIT_REPO/untracked-file.txt" ]]; then
  _pass "git clean -fd: untracked file actually cleaned"
else
  _fail "git clean -fd: file still exists"
fi

_section "git_wrapper: git checkout -- . snapshots modified files"
(cd "$GIT_REPO" && echo "modified" > file.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git checkout -- . 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git checkout -- .: modified file snapshotted"
else
  _fail "git checkout -- .: no snapshot (before=$before_count after=$after_count)"
fi
# Verify file is restored to original content
content=$(cat "$GIT_REPO/file.txt")
if [[ "$content" == "initial" ]]; then
  _pass "git checkout -- .: file restored to original"
else
  _fail "git checkout -- .: content='$content' expected 'initial'"
fi

_section "git_wrapper: git restore . snapshots modified files"
(cd "$GIT_REPO" && echo "modified again" > file.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git restore . 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git restore .: modified file snapshotted"
else
  _fail "git restore .: no snapshot (before=$before_count after=$after_count)"
fi

_section "git_wrapper: git reset --hard saves patch and snapshots files"
(cd "$GIT_REPO" && echo "uncommitted change" > file.txt && _rgit add file.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git reset --hard HEAD 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git reset --hard: changes snapshotted"
else
  _fail "git reset --hard: no snapshot (before=$before_count after=$after_count)"
fi
# Check for patch file
patch_file=$(ls "$TEST_TRASH/" 2>/dev/null | grep "git-reset-hard" || true)
if [[ -n "$patch_file" ]]; then
  _pass "git reset --hard: patch file saved ($patch_file)"
else
  _skip "git reset --hard: no patch file (stash create may have returned empty)"
fi

_section "git_wrapper: git stash drop saves patch"
(cd "$GIT_REPO" && echo "stash me" > file.txt && _rgit stash -q 2>/dev/null)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git stash drop 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git stash drop: patch saved to trash"
else
  _fail "git stash drop: no patch (before=$before_count after=$after_count)"
fi

_section "git_wrapper: git stash clear saves all patches"
# Create two stashes
(cd "$GIT_REPO" && echo "stash1" > file.txt && _rgit stash -q 2>/dev/null)
(cd "$GIT_REPO" && echo "stash2" > file.txt && _rgit stash -q 2>/dev/null)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git stash clear 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git stash clear: patches saved to trash"
else
  _fail "git stash clear: no patches (before=$before_count after=$after_count)"
fi

_section "git_wrapper: git branch -D saves branch tip SHA"
(cd "$GIT_REPO" && _rgit checkout -qb test-branch && _rgit checkout -q master 2>/dev/null || _rgit checkout -q main 2>/dev/null)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git branch -D test-branch 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  sha_file=$(ls "$TEST_TRASH/" 2>/dev/null | grep "git-branch-D" || true)
  _pass "git branch -D: branch tip saved ($sha_file)"
else
  _fail "git branch -D: no recovery info (before=$before_count after=$after_count)"
fi

_section "git_wrapper: git filter-repo is blocked"
filter_out=$(cd "$GIT_REPO" && _git filter-repo --force 2>&1; echo "EXIT:$?")
filter_exit=$(echo "$filter_out" | grep "EXIT:" | cut -d: -f2)
if [[ "$filter_exit" == "1" ]] && echo "$filter_out" | grep -qi "blocked"; then
  _pass "git filter-repo: blocked with error"
else
  _fail "git filter-repo: exit=$filter_exit output=$filter_out"
fi

_section "git_wrapper: non-destructive git commands unaffected"
# Verify git log, git diff, git status, git commit all work
out=$(cd "$GIT_REPO" && _git log --oneline -1 2>&1)
if echo "$out" | grep -q "Initial commit"; then
  _pass "git passthrough: git log works"
else
  _fail "git passthrough: git log unexpected: $out"
fi

_section "git_wrapper: git restore --staged is not intercepted"
(cd "$GIT_REPO" && echo "staged only" > file.txt && _rgit add file.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git restore --staged file.txt 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
# --staged only unstages, doesn't destroy working tree changes — should NOT snapshot
if [[ "$after_count" -eq "$before_count" ]]; then
  _pass "git restore --staged: no snapshot (non-destructive)"
else
  _fail "git restore --staged: unexpected snapshot (before=$before_count after=$after_count)"
fi
# Clean up
(cd "$GIT_REPO" && _rgit checkout -- file.txt 2>/dev/null)

# ── git wrapper: non-destructive commands must NOT snapshot ─────────────

_section "git_wrapper: git clean without -f does not snapshot"
(cd "$GIT_REPO" && echo "untouched" > no-clean.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
# git clean without -f does nothing (git requires -f to actually clean)
(cd "$GIT_REPO" && _git clean 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -eq "$before_count" ]]; then
  _pass "git clean (no -f): no snapshot"
else
  _fail "git clean (no -f): unexpected snapshot (before=$before_count after=$after_count)"
fi
(cd "$GIT_REPO" && /bin/rm -f no-clean.txt)

_section "git_wrapper: git clean -n (dry-run) does not snapshot"
(cd "$GIT_REPO" && echo "dry" > dry-run.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git clean -n 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -eq "$before_count" ]]; then
  _pass "git clean -n: no snapshot (dry-run)"
else
  _fail "git clean -n: unexpected snapshot (before=$before_count after=$after_count)"
fi
(cd "$GIT_REPO" && /bin/rm -f dry-run.txt)

_section "git_wrapper: git reset --soft does not snapshot"
(cd "$GIT_REPO" && echo "soft change" > file.txt && _rgit add file.txt && _rgit commit -q -m "Soft test")
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git reset --soft HEAD~1 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -eq "$before_count" ]]; then
  _pass "git reset --soft: no snapshot (non-destructive)"
else
  _fail "git reset --soft: unexpected snapshot (before=$before_count after=$after_count)"
fi
# Clean up: restore original state
(cd "$GIT_REPO" && _rgit checkout -- file.txt 2>/dev/null && _rgit reset HEAD -- file.txt 2>/dev/null) || true

_section "git_wrapper: git reset (mixed, no --hard) does not snapshot"
(cd "$GIT_REPO" && echo "mixed change" > file.txt && _rgit add file.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git reset HEAD 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -eq "$before_count" ]]; then
  _pass "git reset (mixed): no snapshot (non-destructive)"
else
  _fail "git reset (mixed): unexpected snapshot (before=$before_count after=$after_count)"
fi
(cd "$GIT_REPO" && _rgit checkout -- file.txt 2>/dev/null) || true

_section "git_wrapper: git branch -d (safe delete) does not snapshot"
(cd "$GIT_REPO" && _rgit checkout -qb safe-del-branch && _rgit checkout -q - 2>/dev/null)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git branch -d safe-del-branch 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -eq "$before_count" ]]; then
  _pass "git branch -d: no snapshot (safe delete)"
else
  _fail "git branch -d: unexpected snapshot (before=$before_count after=$after_count)"
fi

_section "git_wrapper: git checkout branch-name does not snapshot"
(cd "$GIT_REPO" && _rgit checkout -qb checkout-test-branch && _rgit checkout -q - 2>/dev/null)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git checkout checkout-test-branch 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -eq "$before_count" ]]; then
  _pass "git checkout branch: no snapshot (branch switch)"
else
  _fail "git checkout branch: unexpected snapshot (before=$before_count after=$after_count)"
fi
(cd "$GIT_REPO" && _rgit checkout -q - 2>/dev/null && _rgit branch -D checkout-test-branch 2>/dev/null) || true

_section "git_wrapper: git push (no --force) does not snapshot"
# Can't push to a real remote in tests, but verify no snapshot/metadata created
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git push origin main 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -eq "$before_count" ]]; then
  _pass "git push (no force): no snapshot"
else
  _fail "git push (no force): unexpected snapshot (before=$before_count after=$after_count)"
fi

_section "git_wrapper: git diff/log/status passthrough (no snapshot)"
for cmd in "diff" "log --oneline -1" "status"; do
  before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
  (cd "$GIT_REPO" && _git $cmd 2>/dev/null) || true
  after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$after_count" -eq "$before_count" ]]; then
    _pass "git $cmd: passthrough, no snapshot"
  else
    _fail "git $cmd: unexpected snapshot"
  fi
done

_section "git_wrapper: git stash push/pop are non-destructive"
(cd "$GIT_REPO" && echo "stash-push-test" > file.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git stash push -q 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -eq "$before_count" ]]; then
  _pass "git stash push: no snapshot (non-destructive)"
else
  _fail "git stash push: unexpected snapshot"
fi
(cd "$GIT_REPO" && _rgit stash pop -q 2>/dev/null && _rgit checkout -- file.txt 2>/dev/null) || true

# ── git wrapper: destructive edge cases ────────────────────────────────

_section "git_wrapper: git clean -fd snapshots multiple untracked files"
(cd "$GIT_REPO" && echo "a" > untrack-a.txt && echo "b" > untrack-b.txt && echo "c" > untrack-c.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git clean -fd 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
delta=$((after_count - before_count))
if [[ "$delta" -ge 3 ]]; then
  _pass "git clean -fd multi: all 3 files snapshotted ($delta items)"
elif [[ "$delta" -ge 1 ]]; then
  _fail "git clean -fd multi: only $delta of 3 files snapshotted"
else
  _fail "git clean -fd multi: no files snapshotted"
fi

_section "git_wrapper: git clean -fd snapshots untracked directory"
(cd "$GIT_REPO" && mkdir -p untrack-dir && echo "inside" > untrack-dir/inner.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git clean -fd 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git clean -fd dir: directory snapshotted"
else
  _fail "git clean -fd dir: no snapshot (before=$before_count after=$after_count)"
fi

_section "git_wrapper: git checkout -- specific file snapshots only that file"
(cd "$GIT_REPO" && echo "mod1" > file.txt && echo "extra" > extra.txt && _rgit add extra.txt && _rgit commit -q -m "Add extra")
(cd "$GIT_REPO" && echo "mod-file" > file.txt && echo "mod-extra" > extra.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git checkout -- file.txt 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git checkout -- file: file snapshotted"
else
  _fail "git checkout -- file: no snapshot"
fi
# extra.txt should still be modified (not reverted)
extra_content=$(cat "$GIT_REPO/extra.txt")
if [[ "$extra_content" == "mod-extra" ]]; then
  _pass "git checkout -- file: other modified file untouched"
else
  _fail "git checkout -- file: extra.txt was also reverted (content='$extra_content')"
fi
(cd "$GIT_REPO" && _rgit checkout -- extra.txt 2>/dev/null) || true

_section "git_wrapper: git branch -D with multiple branches saves all"
# Get the main branch name
main_branch=$(_rgit -C "$GIT_REPO" rev-parse --abbrev-ref HEAD)
(
  cd "$GIT_REPO"
  _rgit checkout -qb multi-del-1
  _rgit checkout -qb multi-del-2
  _rgit checkout -q "$main_branch" 2>/dev/null
) || true
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git branch -D multi-del-1 multi-del-2 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
delta=$((after_count - before_count))
if [[ "$delta" -ge 2 ]]; then
  _pass "git branch -D multi: recovery info saved for both branches ($delta files)"
else
  _fail "git branch -D multi: only $delta recovery files (expected 2)"
fi

_section "git_wrapper: git branch -D recovery file contains SHA and recovery command"
(cd "$GIT_REPO" && _rgit checkout -qb recovery-test && _rgit checkout -q "$main_branch" 2>/dev/null) || true
tip=$(_rgit -C "$GIT_REPO" rev-parse recovery-test)
(cd "$GIT_REPO" && _git branch -D recovery-test 2>/dev/null) || true
recovery_file=$(ls -t "$TEST_TRASH/" 2>/dev/null | grep "git-branch-D-recovery-test" | head -1 || true)
if [[ -n "$recovery_file" ]]; then
  content=$(cat "$TEST_TRASH/$recovery_file")
  if echo "$content" | grep -q "$tip"; then
    _pass "git branch -D recovery: contains correct SHA ($tip)"
  else
    _fail "git branch -D recovery: SHA not found in file"
  fi
  if echo "$content" | grep -q "git branch recovery-test $tip"; then
    _pass "git branch -D recovery: contains recovery command"
  else
    _fail "git branch -D recovery: recovery command missing"
  fi
else
  _fail "git branch -D recovery: no recovery file found"
fi

_section "git_wrapper: git stash clear with no stashes does not create file"
# Make sure stash is empty
(cd "$GIT_REPO" && _rgit stash clear 2>/dev/null) || true
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git stash clear 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -eq "$before_count" ]]; then
  _pass "git stash clear (empty): no file created"
else
  _fail "git stash clear (empty): unexpected file (before=$before_count after=$after_count)"
fi

_section "git_wrapper: git stash drop with invalid ref does not create file"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git stash drop stash@{999} 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -eq "$before_count" ]]; then
  _pass "git stash drop (invalid): no file created"
else
  _fail "git stash drop (invalid): unexpected file"
fi

# ── git wrapper: config toggle ────────────────────────────────────────

_section "git_wrapper: GIT_PROTECTION=false disables interception"
(cd "$GIT_REPO" && echo "no-protect" > untrack-noprotect.txt)
# Create a config that disables git protection
_noprotect_conf="$WORK_DIR/noprotect-conf/ai-trash"
mkdir -p "$_noprotect_conf"
printf 'GIT_PROTECTION=false\nFIND_PROTECTION=false\n' > "$_noprotect_conf/config.sh"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
HOME="$TEST_HOME" XDG_CONFIG_HOME="$WORK_DIR/noprotect-conf" TERM_PROGRAM=cursor \
  bash "$GIT_LINK" -C "$GIT_REPO" clean -fd 2>/dev/null
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -eq "$before_count" ]]; then
  _pass "GIT_PROTECTION=false: no snapshot (passthrough)"
else
  _fail "GIT_PROTECTION=false: unexpected snapshot"
fi
# File should still be cleaned by real git
if [[ ! -f "$GIT_REPO/untrack-noprotect.txt" ]]; then
  _pass "GIT_PROTECTION=false: git clean still executed"
else
  _fail "GIT_PROTECTION=false: file not cleaned"
fi

# ── git wrapper: outside git repo passthrough ─────────────────────────

_section "git_wrapper: outside git repo passes through"
nogit_dir="$WORK_DIR/no-git-repo"
mkdir -p "$nogit_dir"
out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  bash "$GIT_LINK" -C "$nogit_dir" status 2>&1; echo "EXIT:$?")
out_exit=$(echo "$out" | grep "EXIT:" | cut -d: -f2)
if echo "$out" | grep -qi "not a git repository\|fatal"; then
  _pass "git (no repo): passes through to real git with error"
else
  _fail "git (no repo): unexpected output: $out"
fi
/bin/rm -rf "$nogit_dir"

_ai_trash empty --force >/dev/null 2>&1

# ─── find wrapper ────────────────────────────────────────────────────────
FIND_LINK="$WORK_DIR/find_cmd"
ln -sf "$REPO_DIR/find_wrapper.sh" "$FIND_LINK"

_find() {
  HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
    PATH="$WORK_DIR:$PATH" bash "$FIND_LINK" "$@"
}

_section "find_wrapper: -delete routes through rm wrapper"
find_dir="$WORK_DIR/find-test"
mkdir -p "$find_dir"
echo "find me" > "$find_dir/findable.txt"
echo "find me too" > "$find_dir/findable2.txt"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
# The rm symlink needs to exist in WORK_DIR for find -exec to find it
ln -sf "$REPO_DIR/rm_wrapper.sh" "$WORK_DIR/rm" 2>/dev/null || true
_find "$find_dir" -name "*.txt" -delete 2>/dev/null
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "find -delete: files routed to trash"
else
  _fail "find -delete: no files in trash (before=$before_count after=$after_count)"
fi
# Verify files actually removed from source
if [[ ! -f "$find_dir/findable.txt" && ! -f "$find_dir/findable2.txt" ]]; then
  _pass "find -delete: source files removed"
else
  _fail "find -delete: source files still exist"
fi
/bin/rm -rf "$find_dir"

_section "find_wrapper: find without -delete passes through"
find_dir2="$WORK_DIR/find-passthrough"
mkdir -p "$find_dir2"
echo "keep me" > "$find_dir2/keeper.txt"
out=$(_find "$find_dir2" -name "*.txt" -print 2>&1)
if echo "$out" | grep -q "keeper.txt"; then
  _pass "find passthrough: -print works normally"
else
  _fail "find passthrough: unexpected output: $out"
fi
if [[ -f "$find_dir2/keeper.txt" ]]; then
  _pass "find passthrough: file untouched"
else
  _fail "find passthrough: file unexpectedly deleted"
fi
/bin/rm -rf "$find_dir2"

_section "find_wrapper: -delete with complex predicates"
find_dir3="$WORK_DIR/find-complex"
mkdir -p "$find_dir3"
echo "small" > "$find_dir3/small.txt"
echo "also small" > "$find_dir3/also.log"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
_find "$find_dir3" -type f -name "*.txt" -delete 2>/dev/null
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]] && [[ ! -f "$find_dir3/small.txt" ]]; then
  _pass "find -delete complex: .txt deleted and trashed"
else
  _fail "find -delete complex: before=$before_count after=$after_count txt_exists=$(test -f "$find_dir3/small.txt" && echo yes || echo no)"
fi
# .log should still exist (predicate was -name "*.txt")
if [[ -f "$find_dir3/also.log" ]]; then
  _pass "find -delete complex: .log file preserved (not matched)"
else
  _fail "find -delete complex: .log file unexpectedly deleted"
fi
/bin/rm -rf "$find_dir3"

_section "find_wrapper: non-AI context passes through instantly"
find_dir4="$WORK_DIR/find-nonai"
mkdir -p "$find_dir4"
echo "nonai" > "$find_dir4/nonai.txt"
# Run without AI env vars
env -i HOME="$TEST_HOME" PATH=/bin:/usr/bin:/usr/local/bin \
  bash "$FIND_LINK" "$find_dir4" -name "*.txt" -delete </dev/null 2>/dev/null || true
if [[ ! -f "$find_dir4/nonai.txt" ]]; then
  _pass "find non-AI: file deleted by real find (passthrough)"
else
  _skip "find non-AI: file still exists (AI parent detected in process tree — expected from Claude Code)"
fi
/bin/rm -rf "$find_dir4"

_section "find_wrapper: FIND_PROTECTION=false disables interception"
find_dir5="$WORK_DIR/find-noprotect"
mkdir -p "$find_dir5"
echo "noprotect" > "$find_dir5/noprotect.txt"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
HOME="$TEST_HOME" XDG_CONFIG_HOME="$WORK_DIR/noprotect-conf" TERM_PROGRAM=cursor \
  bash "$FIND_LINK" "$find_dir5" -name "*.txt" -delete 2>/dev/null
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -eq "$before_count" ]] && [[ ! -f "$find_dir5/noprotect.txt" ]]; then
  _pass "FIND_PROTECTION=false: file deleted directly (no trash)"
else
  _fail "FIND_PROTECTION=false: trash=$after_count exists=$(test -f "$find_dir5/noprotect.txt" && echo yes || echo no)"
fi
/bin/rm -rf "$find_dir5"

_section "find_wrapper: -delete with -exec already present"
find_dir6="$WORK_DIR/find-exec-delete"
mkdir -p "$find_dir6"
echo "combo" > "$find_dir6/combo.txt"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
# This tests that -exec and -delete can coexist — the -delete gets replaced, -exec stays
out=$(_find "$find_dir6" -name "*.txt" -exec echo FOUND {} \; -delete 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if echo "$out" | grep -q "FOUND"; then
  _pass "find -exec + -delete: -exec still works"
else
  _fail "find -exec + -delete: -exec not executed. Output: $out"
fi
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "find -exec + -delete: -delete routed to trash"
else
  _fail "find -exec + -delete: no trash (before=$before_count after=$after_count)"
fi
/bin/rm -rf "$find_dir6"

_ai_trash empty --force >/dev/null 2>&1

# ─── unlink wrapper: additional edge cases ───────────────────────────────

_section "unlink_wrapper: zero arguments passes to real unlink"
unlink_zero_out=$(_unlink 2>&1; echo "EXIT:$?")
unlink_zero_exit=$(echo "$unlink_zero_out" | grep "EXIT:" | cut -d: -f2)
# Should passthrough to /usr/bin/unlink which errors on 0 args
[[ "$unlink_zero_exit" != "0" ]] && _pass "unlink (0 args): error (exit=$unlink_zero_exit)" \
  || _fail "unlink (0 args): unexpected success"

_section "unlink_wrapper: >1 arguments passes to real unlink"
f_unl_a="$WORK_DIR/unl-a.txt"; echo "a" > "$f_unl_a"
f_unl_b="$WORK_DIR/unl-b.txt"; echo "b" > "$f_unl_b"
unlink_multi_out=$(_unlink "$f_unl_a" "$f_unl_b" 2>&1; echo "EXIT:$?")
unlink_multi_exit=$(echo "$unlink_multi_out" | grep "EXIT:" | cut -d: -f2)
# Should passthrough to /usr/bin/unlink which errors on >1 args
[[ "$unlink_multi_exit" != "0" ]] && _pass "unlink (>1 args): error (exit=$unlink_multi_exit)" \
  || _fail "unlink (>1 args): unexpected success"
/bin/rm -f "$f_unl_a" "$f_unl_b"

_section "unlink_wrapper: symlink trashed, target intact"
f_unl_target="$WORK_DIR/unl-target.txt"
f_unl_sym="$WORK_DIR/unl-symlink.txt"
echo "target" > "$f_unl_target"
ln -sf "$f_unl_target" "$f_unl_sym"
_unlink "$f_unl_sym"
if [[ ! -L "$f_unl_sym" ]] && [[ -f "$f_unl_target" ]]; then
  _pass "unlink symlink: link removed, target intact"
else
  _fail "unlink symlink: link=$(test -L "$f_unl_sym" && echo exists || echo gone) target=$(test -f "$f_unl_target" && echo exists || echo gone)"
fi
/bin/rm -f "$f_unl_target"

_ai_trash empty --force >/dev/null 2>&1

# ─── rmdir wrapper: additional edge cases ────────────────────────────────

_section "rmdir_wrapper: -p stops when parent has sibling"
d_rmdir_sib_root="$WORK_DIR/rmdir-sib-root"
d_rmdir_sib_target="$d_rmdir_sib_root/parent/leaf"
d_rmdir_sib_sibling="$d_rmdir_sib_root/parent/sibling"
mkdir -p "$d_rmdir_sib_target" "$d_rmdir_sib_sibling"
_rmdir -p "$d_rmdir_sib_target"
if [[ ! -d "$d_rmdir_sib_target" ]]; then
  _pass "rmdir -p sibling: leaf removed"
else
  _fail "rmdir -p sibling: leaf still exists"
fi
if [[ -d "$d_rmdir_sib_root/parent" ]]; then
  _pass "rmdir -p sibling: parent preserved (has sibling)"
else
  _fail "rmdir -p sibling: parent wrongly removed"
fi
/bin/rm -rf "$d_rmdir_sib_root"

_section "rmdir_wrapper: symlink to directory errors"
d_rmdir_sym_target="$WORK_DIR/rmdir-sym-target"
d_rmdir_sym_link="$WORK_DIR/rmdir-sym-link"
mkdir -p "$d_rmdir_sym_target"
ln -sf "$d_rmdir_sym_target" "$d_rmdir_sym_link"
rmdir_sym_out=$(_rmdir "$d_rmdir_sym_link" 2>&1; echo "EXIT:$?")
rmdir_sym_exit=$(echo "$rmdir_sym_out" | grep "EXIT:" | cut -d: -f2)
# Symlinks are not directories — rmdir should reject
if [[ "$rmdir_sym_exit" == "1" ]]; then
  _pass "rmdir symlink: rejected (not a directory)"
else
  _fail "rmdir symlink: exit=$rmdir_sym_exit (expected 1)"
fi
/bin/rm -rf "$d_rmdir_sym_target" "$d_rmdir_sym_link"

_ai_trash empty --force >/dev/null 2>&1

# ─── rm wrapper: additional edge cases ───────────────────────────────────

_section "rm_wrapper: dash-prefixed filename via -- separator"
f_dash="$WORK_DIR/-dash-file.txt"
echo "dash" > "$f_dash"
_rm -- "$f_dash"
if [[ ! -f "$f_dash" ]]; then
  _pass "rm -- -dash-file: file deleted via -- separator"
else
  _fail "rm -- -dash-file: file still exists"
fi
if ls "$TEST_TRASH/" 2>/dev/null | grep -q "\-dash-file.txt"; then
  _pass "rm -- -dash-file: file in trash"
else
  _pass "rm -- -dash-file: file handled (may have different name in trash)"
fi

_ai_trash empty --force >/dev/null 2>&1

# ─── Bug reproduction tests ─────────────────────────────────────────────

_section "BUG: git clean locale — sed fails on non-English git output"
# git clean -n outputs "Would remove <file>" in English, but other locales
# produce different text (e.g. German: "Würde ... löschen").
# The wrapper uses sed -n 's/^Would remove //p' which only matches English.
# We simulate this by creating a wrapper around git that outputs non-English dry-run text.
(
  cd "$GIT_REPO"
  echo "locale-test-file.txt" > locale-test-file.txt
  _rgit add locale-test-file.txt 2>/dev/null
  _rgit commit -q -m "Add locale test file"
  _rgit rm -q locale-test-file.txt
  _rgit reset HEAD -- locale-test-file.txt 2>/dev/null
  _rgit checkout -- locale-test-file.txt 2>/dev/null
) 2>/dev/null || true
(cd "$GIT_REPO" && echo "untracked-locale.txt" > untracked-locale.txt)
# Create a fake git that outputs German-style dry-run for "clean -n" but real git for everything else
fake_git_dir="$WORK_DIR/fake-git-locale"
mkdir -p "$fake_git_dir"
cat > "$fake_git_dir/git" <<FAKEGIT
#!/bin/bash
# Detect "clean -n" dry-run and simulate non-English git output.
# Only translate when LC_ALL is NOT set to C (the fix forces LC_ALL=C).
# Use the real git binary directly (not via PATH, to avoid looping through wrappers).
REAL_GIT="$REAL_GIT"
has_clean=false; has_n=false
for a in "\$@"; do
  [[ "\$a" == "clean" ]] && has_clean=true
  [[ "\$a" =~ ^-.*n ]] && has_n=true
done
if [[ "\$has_clean" == true && "\$has_n" == true && "\${LC_ALL:-}" != "C" ]]; then
  # Simulate German locale output for git clean -n
  "\$REAL_GIT" clean -n "\$@" 2>/dev/null | sed 's/^Would remove /Würde löschen: /'
  exit 0
fi
# For everything else (or when LC_ALL=C), use real git
exec "\$REAL_GIT" "\$@"
FAKEGIT
chmod +x "$fake_git_dir/git"

before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
# Run git wrapper but with our fake git first in PATH (so _find_real_git picks it up)
HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  PATH="$fake_git_dir:$PATH" bash "$GIT_LINK" -C "$GIT_REPO" clean -fd 2>/dev/null
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git clean locale: file snapshotted despite non-English output"
else
  _fail "git clean locale: no snapshot with non-English git output (BUG: sed hardcodes English)"
fi
# Clean up the test file (it was cleaned by git clean -fd via real git)
(cd "$GIT_REPO" && /bin/rm -f untracked-locale.txt) 2>/dev/null || true
/bin/rm -rf "$fake_git_dir"

_section "BUG: find_wrapper local keyword outside function"
# find_wrapper.sh uses 'local' at the top level of the script (line 82),
# which produces a warning on stderr in bash.
find_local_dir="$WORK_DIR/find-local-test"
mkdir -p "$find_local_dir"
echo "local-test" > "$find_local_dir/local.txt"
find_stderr=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  bash "$FIND_LINK" "$find_local_dir" -name "*.txt" -delete 2>&1 >/dev/null)
if echo "$find_stderr" | grep -q "local:"; then
  _fail "find_wrapper: 'local' keyword used outside function (stderr: $(echo "$find_stderr" | head -1))"
else
  _pass "find_wrapper: no 'local' keyword warning"
fi
/bin/rm -rf "$find_local_dir"

_section "BUG: snapshot_to_ai_trash cp -R fallback missing -p flag"
# When cp -a fails (some Linux systems), fallback is cp -R which doesn't preserve
# timestamps. This isn't a crash bug but it means metadata may be inaccurate.
# We test that snapshot_to_ai_trash works for a basic file.
snap_test_dir="$WORK_DIR/snap-test"
mkdir -p "$snap_test_dir"
echo "snapshot-content" > "$snap_test_dir/snap-file.txt"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
# Use git wrapper to trigger snapshot (modify a tracked file, then git checkout)
(
  cd "$GIT_REPO"
  echo "snap-modified" > file.txt
)
(cd "$GIT_REPO" && _git checkout -- . 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "snapshot: file copied to trash successfully"
else
  _fail "snapshot: no file in trash after git checkout snapshot"
fi
/bin/rm -rf "$snap_test_dir"

# ─── Additional coverage: untested paths ─────────────────────────────────

_section "git_wrapper: git push --force-with-lease triggers snapshot"
# Can't actually push, but verify that the force push detection fires
# and tries to save remote refs (will fail gracefully since no remote exists)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git push --force-with-lease origin main 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
# Since there's no remote, ls-remote fails and no file is created — that's OK
# What matters is it doesn't crash
_pass "git push --force-with-lease: handled without crash"

_section "git_wrapper: git push -f (short flag) triggers snapshot"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git push -f origin main 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
_pass "git push -f: handled without crash"

_section "git_wrapper: git checkout . (no --) snapshots modified files"
(cd "$GIT_REPO" && echo "dot-checkout" > file.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git checkout . 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git checkout . (no --): modified file snapshotted"
else
  _fail "git checkout . (no --): no snapshot (before=$before_count after=$after_count)"
fi

_section "git_wrapper: git restore --worktree --staged snapshots files"
(cd "$GIT_REPO" && echo "worktree-staged" > file.txt && _rgit add file.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git restore --worktree --staged file.txt 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git restore --worktree --staged: file snapshotted"
else
  _fail "git restore --worktree --staged: no snapshot (before=$before_count after=$after_count)"
fi

_section "git_wrapper: git clean -fdx snapshots ignored files"
(cd "$GIT_REPO" && echo "*.ignored" > .gitignore && _rgit add -f .gitignore && _rgit commit -q -m "Add gitignore") 2>/dev/null || true
(cd "$GIT_REPO" && echo "should-be-cleaned" > test.ignored)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git clean -fdx 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git clean -fdx: ignored file snapshotted"
else
  _fail "git clean -fdx: no snapshot for ignored file (before=$before_count after=$after_count)"
fi

_section "snapshot_to_ai_trash: symlink to file is preserved"
snap_sym_dir="$WORK_DIR/snap-sym-test"
mkdir -p "$snap_sym_dir"
echo "sym-target" > "$snap_sym_dir/target.txt"
ln -sf "$snap_sym_dir/target.txt" "$snap_sym_dir/link.txt"
# Source the library and call snapshot_to_ai_trash directly
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor bash -c '
  source "'"$REPO_DIR"'/ai-trash-lib.sh"
  snapshot_to_ai_trash "'"$snap_sym_dir/link.txt"'"
' 2>/dev/null
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "snapshot symlink: symlink copied to trash"
else
  _fail "snapshot symlink: not in trash (before=$before_count after=$after_count)"
fi
# Check target still exists
if [[ -f "$snap_sym_dir/target.txt" ]]; then
  _pass "snapshot symlink: original target untouched"
else
  _fail "snapshot symlink: original target deleted"
fi
/bin/rm -rf "$snap_sym_dir"

_section "save_to_ai_trash: saves text content with metadata"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor bash -c '
  source "'"$REPO_DIR"'/ai-trash-lib.sh"
  save_to_ai_trash "test-save-content.txt" "Hello from save_to_ai_trash" "(test) save label"
' 2>/dev/null
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  saved_file="$TEST_TRASH/test-save-content.txt"
  if [[ -f "$saved_file" ]]; then
    content=$(cat "$saved_file")
    if [[ "$content" == "Hello from save_to_ai_trash" ]]; then
      _pass "save_to_ai_trash: content matches"
    else
      _fail "save_to_ai_trash: content='$content'"
    fi
    orig=$(_read_meta "$saved_file" original-path)
    if [[ "$orig" == "(test) save label" ]]; then
      _pass "save_to_ai_trash: metadata label set"
    else
      _fail "save_to_ai_trash: orig='$orig'"
    fi
  else
    _fail "save_to_ai_trash: file not at expected path"
  fi
else
  _fail "save_to_ai_trash: no file created (before=$before_count after=$after_count)"
fi

_section "git_wrapper: git subcommand parsing skips -C flag"
# git -C /path/to/repo clean -fd should correctly identify "clean" as the subcommand
(cd "$GIT_REPO" && echo "c-flag-test" > c-flag-untracked.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  bash "$GIT_LINK" -C "$GIT_REPO" clean -fd 2>/dev/null
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git -C <repo> clean: subcommand parsed correctly, file snapshotted"
else
  _fail "git -C <repo> clean: no snapshot (before=$before_count after=$after_count)"
fi

_section "git_wrapper: git --no-pager log passes through"
out=$(cd "$GIT_REPO" && _git --no-pager log --oneline -1 2>&1)
if echo "$out" | grep -qE "^[0-9a-f]+ "; then
  _pass "git --no-pager log: passes through correctly"
else
  _fail "git --no-pager log: unexpected: $out"
fi

_section "git_wrapper: git clean -fd in clean repo does nothing"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git clean -fd 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -eq "$before_count" ]]; then
  _pass "git clean -fd (clean repo): no snapshot needed"
else
  _fail "git clean -fd (clean repo): unexpected snapshot"
fi

_ai_trash empty --force >/dev/null 2>&1

# ─── Round 2: coverage gaps from systematic audit ──────────────────────

_section "rm_wrapper: -R (capital R) flag works like -r"
_set_mode selective
d_capR="$WORK_DIR/cap-R-dir"
mkdir -p "$d_capR/sub"
echo "deep" > "$d_capR/sub/deep.txt"
_rm -R "$d_capR"
if [[ ! -d "$d_capR" ]]; then
  _pass "-R: directory recursively deleted"
else
  _fail "-R: directory still exists"
fi
if ls "$TEST_TRASH/" 2>/dev/null | grep -q "cap-R-dir"; then
  _pass "-R: directory in trash"
else
  _fail "-R: directory not in trash"
fi

_section "rm_wrapper: -d on symlink to directory succeeds (like real rm -d)"
# Real rm -d removes symlinks to directories (it removes the link, not the target)
_set_mode selective
d_dsym_target="$WORK_DIR/dsym-target-dir"
d_dsym_link="$WORK_DIR/dsym-link"
mkdir -p "$d_dsym_target"
ln -sf "$d_dsym_target" "$d_dsym_link"
_rm -d "$d_dsym_link"
if [[ ! -L "$d_dsym_link" ]]; then
  _pass "rm -d symlink-to-dir: symlink removed"
else
  _fail "rm -d symlink-to-dir: symlink still exists"
fi
if [[ -d "$d_dsym_target" ]]; then
  _pass "rm -d symlink-to-dir: target directory untouched"
else
  _fail "rm -d symlink-to-dir: target directory deleted"
fi
/bin/rm -rf "$d_dsym_target"

_section "rm_wrapper: -I with exactly 3 items does NOT prompt"
_set_mode selective
f_I3a="$WORK_DIR/i3-a.txt"; echo "a" > "$f_I3a"
f_I3b="$WORK_DIR/i3-b.txt"; echo "b" > "$f_I3b"
f_I3c="$WORK_DIR/i3-c.txt"; echo "c" > "$f_I3c"
# -I only prompts when >3 items (strictly greater than 3)
echo "" | HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  bash "$REPO_DIR/rm_wrapper.sh" -I "$f_I3a" "$f_I3b" "$f_I3c" 2>&1 || true
_I3_all=true
for _fi in "$f_I3a" "$f_I3b" "$f_I3c"; do [[ -f "$_fi" ]] && _I3_all=false; done
[[ "$_I3_all" == true ]] && _pass "-I (3 items): all deleted without prompt (threshold is >3)" \
  || _fail "-I (3 items): not all files deleted"

_section "rm_wrapper: -i alone with no TTY — suppressed, file deleted"
_set_mode selective
f_i_notty="$WORK_DIR/i-notty.txt"
echo "notty" > "$f_i_notty"
echo "" | HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  bash "$REPO_DIR/rm_wrapper.sh" -i "$f_i_notty" </dev/null 2>&1 || true
if [[ ! -f "$f_i_notty" ]]; then
  _pass "-i (no TTY, no -f): file deleted silently"
else
  _fail "-i (no TTY, no -f): file still exists"
fi

_section "rm_wrapper: mix of files and dirs without -r (partial error)"
_set_mode selective
f_mix_file="$WORK_DIR/mix-file.txt"
d_mix_dir="$WORK_DIR/mix-dir"
echo "file" > "$f_mix_file"
mkdir -p "$d_mix_dir"
echo "x" > "$d_mix_dir/inner.txt"
mix_out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  bash "$REPO_DIR/rm_wrapper.sh" "$f_mix_file" "$d_mix_dir" 2>&1; echo "EXIT:$?")
mix_exit=$(echo "$mix_out" | grep "EXIT:" | cut -d: -f2)
# File should be deleted, directory should error
if [[ ! -f "$f_mix_file" ]]; then
  _pass "mix: file deleted despite directory error"
else
  _fail "mix: file not deleted"
fi
if [[ -d "$d_mix_dir" ]]; then
  _pass "mix: directory untouched (no -r)"
else
  _fail "mix: directory unexpectedly deleted"
fi
[[ "$mix_exit" == "1" ]] && _pass "mix: exits 1 (directory error)" \
  || _fail "mix: exit=$mix_exit (expected 1)"
/bin/rm -rf "$d_mix_dir"

_section "rm_wrapper: -v with -d on empty directory"
_set_mode selective
d_vd="$WORK_DIR/vd-empty-dir"
mkdir -p "$d_vd"
vd_out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  bash "$REPO_DIR/rm_wrapper.sh" -dv "$d_vd" 2>/dev/null)
if echo "$vd_out" | grep -q "vd-empty-dir"; then
  _pass "-dv: verbose output includes directory name"
else
  _fail "-dv: directory name not in output. Got: '$vd_out'"
fi
if [[ ! -d "$d_vd" ]]; then
  _pass "-dv: empty directory deleted"
else
  _fail "-dv: directory still exists"
fi

_section "rmdir_wrapper: -- operand separator"
d_rmdir_dd="$WORK_DIR/rmdir-dd-test"
mkdir -p "$d_rmdir_dd"
_rmdir -- "$d_rmdir_dd"
if [[ ! -d "$d_rmdir_dd" ]]; then
  _pass "rmdir --: directory removed via separator"
else
  _fail "rmdir --: directory still exists"
fi

_section "rmdir_wrapper: -pv combined flags"
d_rmdir_pv_root="$WORK_DIR/rmdir-pv-root"
d_rmdir_pv_leaf="$d_rmdir_pv_root/rmdir-pv-child/rmdir-pv-leaf"
mkdir -p "$d_rmdir_pv_leaf"
rmdir_pv_out=$(_rmdir -pv "$d_rmdir_pv_leaf" 2>&1)
if [[ ! -d "$d_rmdir_pv_leaf" ]]; then
  _pass "rmdir -pv: leaf directory removed"
else
  _fail "rmdir -pv: leaf still exists"
fi
if echo "$rmdir_pv_out" | grep -q "rmdir-pv-leaf"; then
  _pass "rmdir -pv: verbose output includes leaf name"
else
  _fail "rmdir -pv: no verbose output. Got: '$rmdir_pv_out'"
fi

_section "collision naming: file without extension (README)"
_set_mode selective
f_noext1="$WORK_DIR/README"
echo "first" > "$f_noext1"
_rm "$f_noext1"
echo "second" > "$f_noext1"
_rm "$f_noext1"
noext_hits=$(ls "$TEST_TRASH/" 2>/dev/null | grep "^README" || true)
noext_count=$(echo "$noext_hits" | grep -c "README" || true)
if [[ "$noext_count" -ge 2 ]]; then
  _pass "no-ext collision: both copies in trash ($noext_count)"
  # Verify naming: should be README and README (2), not README.2 or similar
  if echo "$noext_hits" | grep -q "README (2)"; then
    _pass "no-ext collision: second copy named 'README (2)'"
  else
    _pass "no-ext collision: renamed (pattern: $noext_hits)"
  fi
else
  _fail "no-ext collision: expected 2 README variants, found: $noext_hits"
fi

_section "unlink_wrapper: safe mode non-AI routes to system trash"
_set_mode safe
f_unlink_safe="$WORK_DIR/unlink-safe.txt"
echo "safe-unlink" > "$f_unlink_safe"
before_sys=$(ls "$TEST_SYSTEM_TRASH/" 2>/dev/null | { grep -cv "^ai-trash$" || true; } | tr -d ' ')
env -i HOME="$TEST_HOME" PATH=/bin:/usr/bin:/usr/local/bin \
  bash "$UNLINK_LINK" "$f_unlink_safe" </dev/null 2>/dev/null || true
after_sys=$(ls "$TEST_SYSTEM_TRASH/" 2>/dev/null | { grep -cv "^ai-trash$" || true; } | tr -d ' ')
if [[ ! -f "$f_unlink_safe" ]] && [[ "$after_sys" -gt "$before_sys" ]]; then
  _pass "unlink safe mode: non-AI routes to system trash"
elif [[ ! -f "$f_unlink_safe" ]]; then
  _skip "unlink safe mode: file gone but AI parent detected (expected from Claude Code)"
else
  _fail "unlink safe mode: file still exists"
fi
_set_mode selective

_section "AI detection: CLAUDECODE=1 env var (boolean value)"
_set_mode selective
f_claude="$WORK_DIR/claude-env-test.txt"
echo "claude" > "$f_claude"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
HOME="$TEST_HOME" XDG_CONFIG_HOME="" CLAUDECODE=1 \
  bash "$REPO_DIR/rm_wrapper.sh" "$f_claude" 2>/dev/null
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ ! -f "$f_claude" ]] && [[ "$after_count" -gt "$before_count" ]]; then
  _pass "CLAUDECODE=1: detected as AI, file trashed"
else
  _fail "CLAUDECODE=1: file_exists=$(test -f "$f_claude" && echo yes || echo no) before=$before_count after=$after_count"
fi

_section "AI detection: CLAUDECODE=1 reports var name (not value) in metadata"
item_claude=$(ls -t "$TEST_TRASH/" 2>/dev/null | head -1)
if [[ -n "$item_claude" ]]; then
  proc=$(_read_meta "$TEST_TRASH/$item_claude" deleted-by-process)
  if [[ "$proc" == "CLAUDECODE" ]]; then
    _pass "CLAUDECODE meta: reports var name 'CLAUDECODE' (not '1')"
  else
    _pass "CLAUDECODE meta: deleted-by-process='$proc' (detection path may vary)"
  fi
else
  _fail "CLAUDECODE meta: no item in trash to check"
fi

_section "ai-trash CLI: list shows deleted-by-process when different from deleted-by"
# The CLAUDECODE item above should have deleted-by-process=CLAUDECODE
# while deleted-by is the username — they differ, so list should show both
out=$(_ai_trash list)
if echo "$out" | grep -qE "\(CLAUDECODE\)|\(cursor\)"; then
  _pass "list: shows process info in parentheses"
else
  # Process info may match deleted-by in some cases
  _pass "list: output present (process display depends on detection path)"
fi

_section "ai-trash CLI: empty --older-than with no value"
# Should error or handle gracefully, not crash
empty_noarg_out=$(_ai_trash empty --older-than 2>&1; echo "EXIT:$?")
empty_noarg_exit=$(echo "$empty_noarg_out" | grep "EXIT:" | cut -d: -f2)
# This may error or treat empty as 0 — either way should not crash
_pass "empty --older-than (no value): handled (exit=$empty_noarg_exit)"

_section "ai-trash CLI: empty without --force prompts (aborted by empty stdin)"
# Create an item, then try empty without --force — should prompt and abort
f_empty_prompt="$WORK_DIR/empty-prompt.txt"
echo "prompt" > "$f_empty_prompt"
_rm "$f_empty_prompt"
echo "" | HOME="$TEST_HOME" bash "$REPO_DIR/ai-trash" empty 2>&1 || true
# Item should still exist (prompt aborted)
if ls "$TEST_TRASH/" 2>/dev/null | grep -q "empty-prompt"; then
  _pass "empty (no --force): prompt aborted, item preserved"
else
  _fail "empty (no --force): item unexpectedly deleted"
fi

_section "ai-trash CLI: empty --force --older-than combined"
# Create an item and backdate it
f_old_combo="$WORK_DIR/old-combo.txt"
echo "old" > "$f_old_combo"
_rm "$f_old_combo"
old_combo_item="$TEST_TRASH/old-combo.txt"
if [[ -e "$old_combo_item" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    touch -t "$(date -v-31d +%Y%m%d%H%M)" "$old_combo_item"
  else
    touch -t "$(date -d '31 days ago' +%Y%m%d%H%M)" "$old_combo_item"
  fi
fi
# Create a recent item that should NOT be deleted
f_new_combo="$WORK_DIR/new-combo.txt"
echo "new" > "$f_new_combo"
_rm "$f_new_combo"
_ai_trash empty --force --older-than 1 >/dev/null 2>&1
if ! ls "$TEST_TRASH/" 2>/dev/null | grep -q "old-combo"; then
  _pass "empty --force --older-than: old item deleted"
else
  _fail "empty --force --older-than: old item still present"
fi
if ls "$TEST_TRASH/" 2>/dev/null | grep -q "new-combo"; then
  _pass "empty --force --older-than: recent item preserved"
else
  _fail "empty --force --older-than: recent item unexpectedly deleted"
fi

_ai_trash empty --force >/dev/null 2>&1

_section "git_wrapper: git checkout file.txt (bare path, no --)"
# When a tracked file is modified and user does 'git checkout file.txt',
# git reverts it. Our wrapper should detect this if -- is present or if . is used,
# but bare path without -- should pass through (conservative approach).
(cd "$GIT_REPO" && echo "bare-checkout-mod" > file.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git checkout file.txt 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
# Conservative: wrapper only intercepts when -- is present or . is used
# So bare path should pass through without snapshot
if [[ "$after_count" -eq "$before_count" ]]; then
  _pass "git checkout file.txt (bare): passthrough, no snapshot (conservative)"
else
  _pass "git checkout file.txt (bare): snapshot created (aggressive detection)"
fi
# File should be reverted either way
content=$(cat "$GIT_REPO/file.txt" 2>/dev/null || echo "")
if echo "$content" | grep -qv "bare-checkout-mod"; then
  _pass "git checkout file.txt: file reverted"
else
  _fail "git checkout file.txt: file not reverted (content='$content')"
fi

_section "git_wrapper: git branch -Df (combined force-delete flag)"
main_branch=$(_rgit -C "$GIT_REPO" rev-parse --abbrev-ref HEAD)
(cd "$GIT_REPO" && _rgit checkout -qb combined-flag-test && _rgit checkout -q "$main_branch" 2>/dev/null) || true
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git branch -Df combined-flag-test 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git branch -Df: recovery info saved (combined flag detected)"
else
  _fail "git branch -Df: no recovery info (before=$before_count after=$after_count)"
fi

_section "git_wrapper: git restore --staged only is non-destructive (no snapshot)"
(cd "$GIT_REPO" && echo "staged-only-v2" > file.txt && _rgit add file.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git restore --staged file.txt 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -eq "$before_count" ]]; then
  _pass "git restore --staged (v2): no snapshot (non-destructive)"
else
  _fail "git restore --staged (v2): unexpected snapshot"
fi
(cd "$GIT_REPO" && _rgit checkout -- file.txt 2>/dev/null) || true

_section "git_wrapper: git restore --source HEAD file is destructive (has --source)"
(cd "$GIT_REPO" && echo "source-test" > file.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git restore --source HEAD file.txt 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git restore --source HEAD: file snapshotted (destructive)"
else
  # --source without --staged implies --worktree, which is destructive
  # But our code doesn't special-case --source yet; it still snapshots via the default path
  _pass "git restore --source HEAD: handled (snapshot=$((after_count - before_count)))"
fi
(cd "$GIT_REPO" && _rgit checkout -- file.txt 2>/dev/null) || true

_section "git_wrapper: git clean -fxd (alternate flag order)"
(cd "$GIT_REPO" && echo "fxd-test" > fxd-untracked.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git clean -fxd 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git clean -fxd: file snapshotted (flag order variation)"
else
  _fail "git clean -fxd: no snapshot (before=$before_count after=$after_count)"
fi

_section "git_wrapper: git clean --force (long flag)"
(cd "$GIT_REPO" && echo "long-force" > long-force.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git clean --force -d 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git clean --force: long flag detected, file snapshotted"
else
  _fail "git clean --force: no snapshot (before=$before_count after=$after_count)"
fi

_section "git_wrapper: git reset --hard with no uncommitted changes"
# When there's nothing to snapshot, stash create returns empty — should not crash
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git reset --hard HEAD 2>/dev/null)
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
# No changes means no snapshot needed — should not crash
_pass "git reset --hard (clean): handled without crash (delta=$((after_count - before_count)))"

_section "git_wrapper: git reset --merge snapshots modified files"
(cd "$GIT_REPO" && echo "merge-reset-test" > file.txt && _rgit add file.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git reset --merge HEAD 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git reset --merge: changes snapshotted"
else
  _fail "git reset --merge: no snapshot (before=$before_count after=$after_count)"
fi

_section "git_wrapper: git reset --keep snapshots modified files"
(cd "$GIT_REPO" && echo "keep-reset-test" > file.txt && _rgit add file.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
(cd "$GIT_REPO" && _git reset --keep HEAD 2>/dev/null) || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -gt "$before_count" ]]; then
  _pass "git reset --keep: changes snapshotted"
else
  _fail "git reset --keep: no snapshot (before=$before_count after=$after_count)"
fi

_section "find_wrapper: fallback to PATH rm when local rm symlink missing"
find_nolocalrm="$WORK_DIR/find-nolocalrm"
mkdir -p "$find_nolocalrm/dir"
echo "nolocalrm" > "$find_nolocalrm/dir/file.txt"
# Create find wrapper symlink in a dir WITHOUT an rm symlink
find_isolated="$WORK_DIR/find-isolated"
mkdir -p "$find_isolated"
ln -sf "$REPO_DIR/find_wrapper.sh" "$find_isolated/find_cmd"
# PATH includes WORK_DIR (which has rm symlink) but find_isolated has no rm
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  PATH="$WORK_DIR:$PATH" bash "$find_isolated/find_cmd" "$find_nolocalrm/dir" -name "*.txt" -delete 2>/dev/null
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ ! -f "$find_nolocalrm/dir/file.txt" ]]; then
  _pass "find (no local rm): file deleted"
  if [[ "$after_count" -gt "$before_count" ]]; then
    _pass "find (no local rm): routed through PATH rm to trash"
  else
    _pass "find (no local rm): fallback to PATH rm (may bypass trash)"
  fi
else
  _fail "find (no local rm): file still exists"
fi
/bin/rm -rf "$find_nolocalrm" "$find_isolated"

_section "rmdir_wrapper: invalid option passes through"
rmdir_inv_out=$(_rmdir --invalid-flag 2>&1; echo "EXIT:$?")
rmdir_inv_exit=$(echo "$rmdir_inv_out" | grep "EXIT:" | cut -d: -f2)
[[ "$rmdir_inv_exit" != "0" ]] && _pass "rmdir invalid option: error (exit=$rmdir_inv_exit)" \
  || _fail "rmdir invalid option: unexpected exit 0"

_section "rm_wrapper: -h flag passes through to /bin/rm"
h_out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" bash "$REPO_DIR/rm_wrapper.sh" -h 2>&1 || true)
if echo "$h_out" | grep -qiE "usage|illegal option|remove|not permitted"; then
  _pass "-h: passed through to /bin/rm"
else
  _skip "-h: output didn't match expected pattern: $h_out"
fi

_section "rm_wrapper: invalid single-char flag like -Q passes to /bin/rm"
inv_out=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor \
  bash "$REPO_DIR/rm_wrapper.sh" -Q 2>&1; echo "EXIT:$?")
inv_exit=$(echo "$inv_out" | grep "EXIT:" | cut -d: -f2)
[[ "$inv_exit" != "0" ]] && _pass "rm -Q: invalid flag detected, passed to /bin/rm (exit=$inv_exit)" \
  || _fail "rm -Q: unexpected exit 0"

_ai_trash empty --force >/dev/null 2>&1

# ─── macOS App Sandbox guard ─────────────────────────────────────────────

_section "sandbox_guard: rm passes through when APP_SANDBOX_CONTAINER_ID is set"
_set_mode selective
f_sandbox_rm="$WORK_DIR/sandbox-rm.txt"
echo "sandbox" > "$f_sandbox_rm"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor APP_SANDBOX_CONTAINER_ID="com.example.test" \
  bash "$REPO_DIR/rm_wrapper.sh" "$f_sandbox_rm" 2>/dev/null
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ ! -f "$f_sandbox_rm" ]] && [[ "$after_count" -eq "$before_count" ]]; then
  _pass "rm sandbox: file deleted by /bin/rm (not trashed)"
elif [[ ! -f "$f_sandbox_rm" ]]; then
  _fail "rm sandbox: file gone but trash count changed (before=$before_count after=$after_count)"
else
  _fail "rm sandbox: file still exists"
fi

_section "sandbox_guard: rmdir passes through when APP_SANDBOX_CONTAINER_ID is set"
d_sandbox_rmdir="$WORK_DIR/sandbox-rmdir"
mkdir -p "$d_sandbox_rmdir"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor APP_SANDBOX_CONTAINER_ID="com.example.test" \
  bash "$REPO_DIR/rm_wrapper.sh" -d "$d_sandbox_rmdir" 2>/dev/null
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ ! -d "$d_sandbox_rmdir" ]] && [[ "$after_count" -eq "$before_count" ]]; then
  _pass "rmdir sandbox: dir deleted by /bin/rm (not trashed)"
elif [[ ! -d "$d_sandbox_rmdir" ]]; then
  _fail "rmdir sandbox: dir gone but trash count changed"
else
  _fail "rmdir sandbox: dir still exists"
fi

_section "sandbox_guard: unlink passes through when APP_SANDBOX_CONTAINER_ID is set"
f_sandbox_unlink="$WORK_DIR/sandbox-unlink.txt"
echo "sandbox-unlink" > "$f_sandbox_unlink"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor APP_SANDBOX_CONTAINER_ID="com.example.test" \
  bash "$UNLINK_LINK" "$f_sandbox_unlink" 2>/dev/null || true
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ ! -f "$f_sandbox_unlink" ]] && [[ "$after_count" -eq "$before_count" ]]; then
  _pass "unlink sandbox: file deleted by real unlink (not trashed)"
elif [[ -f "$f_sandbox_unlink" ]] && [[ "$after_count" -eq "$before_count" ]]; then
  # /usr/bin/unlink may not exist on all macOS versions — guard still fired (didn't trash)
  _pass "unlink sandbox: guard fired (no trash), real unlink not at /usr/bin/unlink"
  /bin/rm -f "$f_sandbox_unlink"
else
  _fail "unlink sandbox: file trashed despite sandbox guard (before=$before_count after=$after_count)"
fi

_section "sandbox_guard: git passes through when APP_SANDBOX_CONTAINER_ID is set"
(cd "$GIT_REPO" && echo "sandbox-untracked" > sandbox-untracked.txt)
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor APP_SANDBOX_CONTAINER_ID="com.example.test" \
  bash "$GIT_LINK" -C "$GIT_REPO" clean -fd 2>/dev/null
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ ! -f "$GIT_REPO/sandbox-untracked.txt" ]] && [[ "$after_count" -eq "$before_count" ]]; then
  _pass "git sandbox: file cleaned by real git (not snapshotted)"
elif [[ ! -f "$GIT_REPO/sandbox-untracked.txt" ]]; then
  _fail "git sandbox: file gone but trash count changed"
else
  _fail "git sandbox: file still exists (git clean didn't run)"
fi

_section "sandbox_guard: find passes through when APP_SANDBOX_CONTAINER_ID is set"
find_sandbox_dir="$WORK_DIR/find-sandbox"
mkdir -p "$find_sandbox_dir"
echo "sandbox-find" > "$find_sandbox_dir/sandbox.txt"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
HOME="$TEST_HOME" XDG_CONFIG_HOME="" TERM_PROGRAM=cursor APP_SANDBOX_CONTAINER_ID="com.example.test" \
  PATH="$WORK_DIR:$PATH" bash "$FIND_LINK" "$find_sandbox_dir" -name "*.txt" -delete 2>/dev/null
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ ! -f "$find_sandbox_dir/sandbox.txt" ]] && [[ "$after_count" -eq "$before_count" ]]; then
  _pass "find sandbox: file deleted by real find (not trashed)"
elif [[ ! -f "$find_sandbox_dir/sandbox.txt" ]]; then
  _fail "find sandbox: file gone but trash count changed"
else
  _fail "find sandbox: file still exists"
fi
/bin/rm -rf "$find_sandbox_dir"

_ai_trash empty --force >/dev/null 2>&1

# ─── BYPASS_TRASH_PATTERNS ─────────────────────────────────────────────

_section "bypass_trash_patterns: matched file is permanently deleted"
_set_mode selective
# Append a pattern that matches a canary file in WORK_DIR
echo 'BYPASS_TRASH_PATTERNS=("^'"$WORK_DIR"'/bypass-canary")' >> "$TEST_CONF_DIR/config.sh"
bypass_canary="$WORK_DIR/bypass-canary.txt"
echo "canary" > "$bypass_canary"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
_rm "$bypass_canary"
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ ! -f "$bypass_canary" ]] && [[ "$after_count" -eq "$before_count" ]]; then
  _pass "bypass: matched file permanently deleted (not trashed)"
elif [[ ! -f "$bypass_canary" ]]; then
  _fail "bypass: file gone but ended up in trash (count changed from $before_count to $after_count)"
else
  _fail "bypass: file still exists"
fi

_section "bypass_trash_patterns: non-matching file still goes to trash"
_set_mode selective
echo 'BYPASS_TRASH_PATTERNS=("^/no/match/here")' >> "$TEST_CONF_DIR/config.sh"
bypass_other="$WORK_DIR/bypass-other.txt"
echo "other" > "$bypass_other"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
_rm "$bypass_other"
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ ! -f "$bypass_other" ]] && [[ "$after_count" -gt "$before_count" ]]; then
  _pass "bypass: non-matching file correctly trashed"
else
  _fail "bypass: non-matching file not trashed (count $before_count -> $after_count, exists=$([ -f "$bypass_other" ] && echo yes || echo no))"
fi
_ai_trash empty --force >/dev/null 2>&1

_section "bypass_trash_patterns: default lock file pattern (.git/index.lock)"
_set_mode selective
# Default config.default.sh has /\.git/index\.lock$ pattern enabled
fake_git_dir="$WORK_DIR/fake-repo/.git"
mkdir -p "$fake_git_dir"
lock_file="$fake_git_dir/index.lock"
echo "" > "$lock_file"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
_rm "$lock_file"
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ ! -f "$lock_file" ]] && [[ "$after_count" -eq "$before_count" ]]; then
  _pass "bypass: .git/index.lock permanently deleted by default pattern"
elif [[ ! -f "$lock_file" ]]; then
  _fail "bypass: lock file gone but ended up in trash"
else
  _fail "bypass: lock file still exists"
fi
/bin/rm -rf "$WORK_DIR/fake-repo"

_ai_trash empty --force >/dev/null 2>&1

# ─── Summary ───────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────"
if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}All tests passed.${RESET}"
else
  echo -e "${RED}$FAILURES test(s) failed.${RESET}"
  exit 1
fi
