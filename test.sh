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
  TEST_TRASH="$TEST_HOME/.Trash/ai-trash"
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

# Run rm_wrapper.sh with overridden HOME (isolates config + trash)
_rm() {
  HOME="$TEST_HOME" bash "$REPO_DIR/rm_wrapper.sh" "$@"
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
_set_mode always
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

_section "rm_wrapper: always mode — directory goes to ai-trash"
d="$WORK_DIR/testdir"
mkdir -p "$d/subdir"
echo "x" > "$d/file.txt"
_rm -rf "$d"
if ls "$TEST_TRASH/" 2>/dev/null | grep -q "testdir"; then
  _pass "always: directory moved to ai-trash"
else
  _fail "always: directory not found in ai-trash. Contents: $(ls $TEST_TRASH/ 2>/dev/null || echo 'empty')"
fi

_section "rm_wrapper: disposable patterns — .log file permanently deleted"
_set_mode always
f_log="$WORK_DIR/debug.log"
echo "log content" > "$f_log"
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
_rm "$f_log"
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -eq "$before_count" ]] && [[ ! -f "$f_log" ]]; then
  _pass "disposable: .log file permanently deleted (not in ai-trash)"
else
  _fail "disposable: unexpected — before=$before_count after=$after_count file_exists=$(test -f $f_log && echo yes || echo no)"
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
_set_mode always
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
_set_mode always
f_i="$WORK_DIR/interactive-test.txt"
echo "x" > "$f_i"
echo "" | HOME="$TEST_HOME" bash "$REPO_DIR/rm_wrapper.sh" -i "$f_i" 2>&1 || true
if [[ ! -f "$f_i" ]]; then
  _pass "-i suppressed (no TTY): file deleted without hanging"
else
  _fail "-i suppressed: file still exists"
fi

_section "rm_wrapper: missing file with -f — exits 0"
_set_mode always
out=$(HOME="$TEST_HOME" bash "$REPO_DIR/rm_wrapper.sh" -f "$WORK_DIR/does-not-exist.txt" 2>&1; echo "EXIT:$?")
exit_val=$(echo "$out" | grep "EXIT:" | cut -d: -f2)
[[ "$exit_val" == "0" ]] && _pass "-f on missing file exits 0" || _fail "-f on missing file exits $exit_val"

_section "rm_wrapper: missing file without -f — exits 1"
_set_mode always
out=$(HOME="$TEST_HOME" bash "$REPO_DIR/rm_wrapper.sh" "$WORK_DIR/does-not-exist.txt" 2>&1; echo "EXIT:$?") || true
exit_val=$(echo "$out" | grep "EXIT:" | cut -d: -f2)
[[ "$exit_val" == "1" ]] && _pass "missing file without -f exits 1" || _fail "missing file exits $exit_val"

_section "ai-trash CLI: empty --older-than (recent items not deleted)"
_set_mode always
# Items just added should not be deleted with --older-than 1
before_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
_ai_trash empty --force --older-than 1 >/dev/null 2>&1
after_count=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
[[ "$before_count" -eq "$after_count" ]] && _pass "empty --older-than 1: recent items untouched" \
  || _fail "empty --older-than 1: item count changed ($before_count → $after_count)"

_section "ai-trash CLI: empty --force"
before=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
_ai_trash empty --force >/dev/null 2>&1
after=$(ls "$TEST_TRASH/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after" -eq 0 ]]; then
  _pass "empty --force: trash cleared (was $before items)"
else
  _fail "empty --force: $after items remain"
fi

_section "ai-trash CLI: status after empty"
out=$(_ai_trash status)
if echo "$out" | grep -q "AI trash is empty"; then
  _pass "status: empty after empty --force"
else
  _fail "status: unexpected output after empty: $out"
fi

_section "rm_wrapper: --help passes through to /bin/rm"
out=$(HOME="$TEST_HOME" bash "$REPO_DIR/rm_wrapper.sh" --help 2>&1 || true)
if echo "$out" | grep -qiE "usage|illegal option|remove"; then
  _pass "--help passed through to /bin/rm"
else
  _skip "--help: output didn't match expected pattern (may vary by platform): $out"
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
