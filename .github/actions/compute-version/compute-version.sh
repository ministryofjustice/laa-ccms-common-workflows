#!/usr/bin/env bash
# compute-version.sh — version-planning logic for the compute-version composite action.
# Outputs (written to $GITHUB_OUTPUT when set, or stdout for testing):
#   prev_tag, bump_type, major, minor, patch, next_version
set -euo pipefail

REPO_NAME="$(basename "$(git rev-parse --show-toplevel)")"

# Tag resolution: prefer v-prefix tags (new scheme); fall back to {repo-name}-{version}
# (old Gradle Release Plugin scheme). Fallback can be removed once all repositories
# have at least one v-prefix Release Tag.
PREV_TAG="$(git describe --tags --abbrev=0 --match "v[0-9]*" 2>/dev/null || true)"
if [ -z "$PREV_TAG" ]; then
  OLD_TAG="$(git describe --tags --abbrev=0 --match "${REPO_NAME}-[0-9]*" 2>/dev/null || true)"
  if [ -n "$OLD_TAG" ]; then PREV_TAG="v${OLD_TAG#${REPO_NAME}-}"; fi
fi
PREV_TAG="${PREV_TAG:-v0.0.0}"

if git rev-parse -q --verify "$PREV_TAG" >/dev/null 2>&1; then COMMITS="${PREV_TAG}..HEAD"; else COMMITS="HEAD"; fi

# Bump-type detection: use BUMP_OVERRIDE if set, otherwise detect from Conventional Commits
BUMP="none"
if [[ -n "${BUMP_OVERRIDE:-}" ]]; then
  BUMP="$BUMP_OVERRIDE"
elif (git log --no-merges --format=%s  "$COMMITS" | grep -Eqm1 '^[a-z]+(\([^)]+\))?!: ');          then BUMP="major"
elif (git log --no-merges --format=%B  "$COMMITS" | grep -Eqm1 'BREAKING[ -]CHANGE:');              then BUMP="major"
elif (git log --no-merges --format=%s  "$COMMITS" | grep -Eqm1 '^feat(\([^)]+\))?: ');              then BUMP="minor"
elif (git log --no-merges --format=%s  "$COMMITS" | grep -Eqm1 '^(fix|chore|refactor)(\([^)]+\))?: '); then BUMP="patch"
fi

# Semver arithmetic
if [[ "$PREV_TAG" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  MAJOR=${BASH_REMATCH[1]}; MINOR=${BASH_REMATCH[2]}; PATCH=${BASH_REMATCH[3]}
else
  MAJOR=0; MINOR=0; PATCH=0
fi
case "$BUMP" in
  major) MAJOR=$((MAJOR+1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR+1)); PATCH=0 ;;
  patch) PATCH=$((PATCH+1)) ;;
  none)  ;;
esac

NEXT_VERSION=""
if [[ "$BUMP" != "none" ]]; then NEXT_VERSION="v${MAJOR}.${MINOR}.${PATCH}"; fi

emit() {
  echo "$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1" >> "$GITHUB_OUTPUT"; fi
}

emit "prev_tag=${PREV_TAG}"
emit "bump_type=${BUMP}"
emit "major=${MAJOR}"
emit "minor=${MINOR}"
emit "patch=${PATCH}"
emit "next_version=${NEXT_VERSION}"
