#!/bin/bash
# check-release-published.sh: verify a version was fully released, not just tagged.
#
# Usage: ./scripts/check-release-published.sh [v1.6.24]
#        (defaults to the most recent tag)
#
# A tag is not a release. Cutting one leaves five artifacts that can each be
# missing independently, and nothing else notices: the version string in the
# `ai-trash` CLI, the pushed tag, green CI on that tag, the Homebrew formula
# pointing at the tag's tarball with a matching sha256, and a published GitHub
# Release. This checks all five and exits non-zero on the first that is absent,
# so "I don't see it on GitHub" is caught by a command rather than by a person.
#
# Read-only: performs no pushes, edits, or release mutations.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; RESET='\033[0m'
FAILURES=0
_ok()   { echo -e "${GREEN}  OK  ${RESET} $*"; }
_bad()  { echo -e "${RED}  BAD ${RESET} $*"; FAILURES=$(( FAILURES + 1 )); }
_warn() { echo -e "${YELLOW} WARN ${RESET} $*"; }

TAG="${1:-$(git describe --tags --abbrev=0 2>/dev/null)}"
if [[ -z "$TAG" ]]; then
  echo "error: no tag given and no tags found" >&2
  exit 2
fi
BARE="${TAG#v}"
REPO="forethought-studio/ai-trash"

echo "Checking release ${TAG}"
echo ""

# 1. The CLI reports this version.
if git show "${TAG}:ai-trash" 2>/dev/null | grep -qF "ai-trash ${BARE}"; then
  _ok "ai-trash CLI at ${TAG} reports version ${BARE}"
else
  _bad "ai-trash CLI at ${TAG} does not report version ${BARE}"
fi

# 2. The tag exists on the remote, not just locally.
if git ls-remote --tags origin "refs/tags/${TAG}" 2>/dev/null | grep -q .; then
  _ok "tag ${TAG} is pushed to origin"
else
  _bad "tag ${TAG} exists locally but was never pushed"
fi

# 3. CI is green on that tag. An unreadable result is inconclusive, not a pass.
if command -v gh >/dev/null 2>&1; then
  ci=$(gh run list --branch "$TAG" --limit 10 \
         --json conclusion,name -q '.[] | .name + "=" + (.conclusion // "pending")' 2>/dev/null)
  if [[ -z "$ci" ]]; then
    _warn "no CI runs found for ${TAG} (inconclusive, not a pass)"
  elif grep -q "=failure" <<<"$ci"; then
    _bad "CI failed on ${TAG}: $(grep '=failure' <<<"$ci" | tr '\n' ' ')"
  elif grep -q "=pending" <<<"$ci"; then
    _warn "CI still running on ${TAG}: $(grep '=pending' <<<"$ci" | tr '\n' ' ')"
  else
    _ok "CI green on ${TAG}: $(tr '\n' ' ' <<<"$ci")"
  fi
else
  _warn "gh not installed; skipped CI and Release checks (inconclusive)"
fi

# 4. The formula points at this tag, with a sha256 matching the real tarball.
formula_url=$(grep -o 'refs/tags/v[0-9.]*\.tar\.gz' Formula/ai-trash.rb | head -1)
if [[ "$formula_url" == "refs/tags/${TAG}.tar.gz" ]]; then
  _ok "Formula url points at ${TAG}"
else
  _bad "Formula url points at ${formula_url:-<none>}, expected refs/tags/${TAG}.tar.gz"
fi

formula_sha=$(grep -oE 'sha256 "[0-9a-f]{64}"' Formula/ai-trash.rb | head -1 | grep -oE '[0-9a-f]{64}')
actual_sha=$(curl -fsL "https://github.com/${REPO}/archive/refs/tags/${TAG}.tar.gz" 2>/dev/null | shasum -a 256 | awk '{print $1}')
if [[ -z "$actual_sha" || ${#actual_sha} -ne 64 ]]; then
  _warn "could not fetch the ${TAG} tarball to verify sha256 (inconclusive)"
elif [[ "$formula_sha" == "$actual_sha" ]]; then
  _ok "Formula sha256 matches the published ${TAG} tarball"
else
  _bad "Formula sha256 ${formula_sha:-<none>} != tarball ${actual_sha}"
fi

# 5. A GitHub Release exists for the tag. This is the step a plain
#    `git push origin <tag>` does NOT do, and the one most often missed.
if command -v gh >/dev/null 2>&1; then
  if gh release view "$TAG" --json tagName -q .tagName >/dev/null 2>&1; then
    latest=$(gh release list --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null)
    _ok "GitHub Release ${TAG} is published"
    [[ "$latest" == "$TAG" ]] \
      || _warn "GitHub Release ${TAG} exists but ${latest} is marked Latest"
  else
    _bad "no GitHub Release for ${TAG} (the tag alone is not a release)"
  fi
fi

echo ""
if (( FAILURES > 0 )); then
  echo -e "${RED}${FAILURES} problem(s): ${TAG} is not fully released.${RESET}"
  exit 1
fi
echo -e "${GREEN}${TAG} is fully released.${RESET}"
