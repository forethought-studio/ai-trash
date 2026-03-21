#!/bin/bash
# release.sh — bump version, commit, and tag a new release
#
# Usage: ./release.sh 1.0.2
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>  (e.g. $0 1.0.2)" >&2
  exit 1
fi

# Normalise: strip leading 'v', tag always has it
BARE="${VERSION#v}"
TAG="v${BARE}"

# Must be run from repo root
cd "$(dirname "${BASH_SOURCE[0]}")"

# Refuse to run with uncommitted changes
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is dirty — commit or stash changes first" >&2
  exit 1
fi

# Refuse if tag already exists
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists" >&2
  exit 1
fi

# Update version string in ai-trash
sed -i '' "s/echo \"ai-trash [0-9][0-9.]*\"/echo \"ai-trash ${BARE}\"/" ai-trash

# Verify the update landed
if ! grep -qF "ai-trash ${BARE}" ai-trash; then
  echo "error: version update failed — check the version pattern in ai-trash" >&2
  git checkout ai-trash
  exit 1
fi

git add ai-trash
git commit -m "Bump version to ${TAG}"
git tag "${TAG}"

echo ""
echo "Tagged ${TAG}. Push with:"
echo "  git push && git push origin ${TAG}"
echo ""
echo "Then update Formula/ai-trash.rb sha256:"
echo "  curl -sL https://github.com/forethought-studio/ai-trash/archive/refs/tags/${TAG}.tar.gz | shasum -a 256"
