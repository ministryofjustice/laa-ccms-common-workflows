#!/usr/bin/env bash
# Tests for the compute-version composite action bash logic.
# Extracted logic lives in .github/actions/compute-version/compute-version.sh
# Run: bash scripts/test-compute-version.sh
set -euo pipefail

SCRIPT="$(dirname "$0")/../.github/actions/compute-version/compute-version.sh"
PASS=0; FAIL=0

# ── helpers ──────────────────────────────────────────────────────────────────

make_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@test.com"
  git -C "$dir" config user.name  "Test"
  echo "$dir"
}

commit() {
  local dir="$1" msg="$2"
  echo "$RANDOM" > "$dir/f.txt"
  git -C "$dir" add f.txt
  git -C "$dir" commit -qm "$msg"
}

tag_v() { git -C "$1" tag -a "$2" -m "$2"; }

run_script() {
  local dir="$1"
  (cd "$dir" && bash "$SCRIPT")
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL: $label"
    echo "        expected='$expected' actual='$actual'"
    FAIL=$((FAIL+1))
  fi
}

parse_output() {
  local output="$1" key="$2"
  echo "$output" | grep "^${key}=" | cut -d= -f2-
}

# ── TEST 1: feat!: (breaking, no scope) → major bump ─────────────────────────
echo "TEST 1: feat!: commit → major bump"
D=$(make_repo)
commit "$D" "chore: init"
tag_v  "$D" "v1.2.3"
commit "$D" "feat!: remove deprecated API"
OUT=$(run_script "$D")
assert_eq "bump_type=major"      "major"   "$(parse_output "$OUT" bump_type)"
assert_eq "next_version=v2.0.0"  "v2.0.0"  "$(parse_output "$OUT" next_version)"
assert_eq "prev_tag=v1.2.3"      "v1.2.3"  "$(parse_output "$OUT" prev_tag)"


# ── TEST 2: BREAKING CHANGE in commit body → major bump ──────────────────────
echo "TEST 2: BREAKING CHANGE in body → major bump"
D=$(make_repo)
commit "$D" "chore: init"
tag_v  "$D" "v1.2.3"
# multi-line body with BREAKING CHANGE
git -C "$D" add f.txt || true
echo "$RANDOM" > "$D/f.txt"; git -C "$D" add f.txt
git -C "$D" commit -qm $'feat: overhaul auth\n\nBREAKING CHANGE: removed old endpoint'
OUT=$(run_script "$D")
assert_eq "bump_type=major"     "major"   "$(parse_output "$OUT" bump_type)"
assert_eq "next_version=v2.0.0" "v2.0.0"  "$(parse_output "$OUT" next_version)"

# ── TEST 3: feat: → minor bump ────────────────────────────────────────────────
echo "TEST 3: feat: → minor bump"
D=$(make_repo)
commit "$D" "chore: init"
tag_v  "$D" "v1.2.3"
commit "$D" "feat: add dark mode"
OUT=$(run_script "$D")
assert_eq "bump_type=minor"     "minor"   "$(parse_output "$OUT" bump_type)"
assert_eq "next_version=v1.3.0" "v1.3.0"  "$(parse_output "$OUT" next_version)"

# ── TEST 4: fix: → patch bump ─────────────────────────────────────────────────
echo "TEST 4: fix: → patch bump"
D=$(make_repo)
commit "$D" "chore: init"
tag_v  "$D" "v1.2.3"
commit "$D" "fix: null pointer on startup"
OUT=$(run_script "$D")
assert_eq "bump_type=patch"     "patch"   "$(parse_output "$OUT" bump_type)"
assert_eq "next_version=v1.2.4" "v1.2.4"  "$(parse_output "$OUT" next_version)"

# ── TEST 5: no releasable commits → none ──────────────────────────────────────
echo "TEST 5: no releasable commits → none"
D=$(make_repo)
commit "$D" "chore: init"
tag_v  "$D" "v1.2.3"
commit "$D" "docs: update readme"
OUT=$(run_script "$D")
assert_eq "bump_type=none"     "none" "$(parse_output "$OUT" bump_type)"
assert_eq "next_version empty" ""     "$(parse_output "$OUT" next_version)"

# ── TEST 6: no v* tags, old {repo-name}-1.2.3 tag → fallback ─────────────────
echo "TEST 6: old-format tag fallback"
D=$(make_repo)
REPO="$(basename "$D")"
commit "$D" "chore: init"
git -C "$D" tag -a "${REPO}-1.2.3" -m "release"
commit "$D" "fix: something"
OUT=$(run_script "$D")
assert_eq "prev_tag resolved"   "v1.2.3" "$(parse_output "$OUT" prev_tag)"
assert_eq "bump_type=patch"     "patch"   "$(parse_output "$OUT" bump_type)"
assert_eq "next_version=v1.2.4" "v1.2.4"  "$(parse_output "$OUT" next_version)"

# ── TEST 7: no tags at all → default v0.0.0 ──────────────────────────────────
echo "TEST 7: no tags → default v0.0.0"
D=$(make_repo)
commit "$D" "fix: first fix"
OUT=$(run_script "$D")
assert_eq "prev_tag=v0.0.0"    "v0.0.0"  "$(parse_output "$OUT" prev_tag)"
assert_eq "bump_type=patch"    "patch"    "$(parse_output "$OUT" bump_type)"
assert_eq "next_version=v0.0.1" "v0.0.1" "$(parse_output "$OUT" next_version)"

# ── TEST 8: feat(scope)!: (scoped breaking) → major bump ─────────────────────
echo "TEST 8: feat(scope)!: scoped breaking change → major bump"
D=$(make_repo)
commit "$D" "chore: init"
tag_v  "$D" "v1.2.3"
commit "$D" "feat(api)!: remove v1 endpoints"
OUT=$(run_script "$D")
assert_eq "bump_type=major"     "major"   "$(parse_output "$OUT" bump_type)"
assert_eq "next_version=v2.0.0" "v2.0.0"  "$(parse_output "$OUT" next_version)"


# ── TEST 9: explicit bump override ignores commit content ─────────────────────
echo "TEST 9: explicit bump=minor with only fix: commit → respects minor override"
D=$(make_repo)
commit "$D" "chore: init"
tag_v  "$D" "v1.2.3"
commit "$D" "fix: boring bugfix"
OUT=$(BUMP_OVERRIDE=minor run_script "$D")
assert_eq "bump_type=minor"     "minor"   "$(parse_output "$OUT" bump_type)"
assert_eq "next_version=v1.3.0" "v1.3.0"  "$(parse_output "$OUT" next_version)"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
