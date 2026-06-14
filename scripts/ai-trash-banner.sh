# ai-trash-banner.sh -- print the PATH-shadow warning banner if one is pending.
#
# Sourced from the user's shell rc (zsh or bash). check-path-shadows.sh writes
# the flag file when it finds a duplicate command wrapper it cannot safely
# auto-fix (a foreign, unguarded script stacked on a wrapped command). The same
# scan deletes the flag once PATH is clean again, so this banner self-clears --
# it nags on every new shell only until the duplicate is resolved.
#
# Intentionally dependency-free and side-effect-free beyond printing. Safe to
# source from a non-interactive shell (it prints nothing unless the flag exists).
_ait_banner_flag="${AI_TRASH_STATE_DIR:-$HOME/.ai-trash}/path-shadow-warning"
if [ -f "$_ait_banner_flag" ]; then
  printf '\033[1;33m'                                   # bold yellow
  printf '%s\n' '=========================================================='
  cat "$_ait_banner_flag" 2>/dev/null
  printf '%s\n' 'Run check-path-shadows.sh for detail. This clears itself'
  printf '%s\n' 'automatically once the duplicate is gone.'
  printf '%s\n' '=========================================================='
  printf '\033[0m'                                       # reset
fi
unset _ait_banner_flag
