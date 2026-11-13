#!/usr/bin/env bash

set -euo pipefail

# Run the complete upstream-sync test scenario.
run_upstream_sync_tests() {
  # Set KEEP_TEST_REPO=true to inspect the temporary repository after testing.
  SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  SYNC_SCRIPT="${SCRIPT_DIR}/upstream-sync.sh"
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/upstream-sync-test.XXXXXX") || \
    fail "failed to create temporary test repository"
  trap cleanup EXIT

  create_test_repository

  export UPSTREAM_REMOTE=upstream
  export UPSTREAM_BRANCH=main
  export DOWNSTREAM_REMOTE=origin
  export DOWNSTREAM_BRANCH=main
  export UPSTREAM_REPO=test/upstream
  export DOWNSTREAM_REPO=test/downstream
  unset SYNC_IGNORE_FILE

  # shellcheck source=upstream-sync.sh
  source "$SYNC_SCRIPT"

  MERGE_BASE=$(git merge-base upstream/main origin/main)
  EXPECTED_MERGE_BASE=$(git rev-parse refs/test/base)
  [[ "$MERGE_BASE" == "$EXPECTED_MERGE_BASE" ]] || fail "unexpected merge base"
  EXPECTED_IGNORE_FILE="$(pwd -P)/.upstream-sync-ignore"
  [[ "$SYNC_IGNORE_FILE" == "$EXPECTED_IGNORE_FILE" ]] || fail "ignore file is not rooted in the test repository"

  GH_CHANGED_FILES=""
  assert_keep "1 - new-file-only PR is kept" "new.txt"
  assert_skip \
    "2 - downstream-deleted-file-only PR is skipped" \
    "all changed files existed at merge base but were deleted downstream" \
    "deleted.txt"
  assert_keep "3 - existing and new files are kept together" $'existing.txt\nnew.txt'
  assert_keep "4 - deleted and new files are kept together" $'deleted.txt\nnew.txt'
  assert_keep "5 - existing and deleted files are kept together" $'existing.txt\ndeleted.txt'
  assert_skip \
    "6 - fully ignored PR is skipped" \
    "all changed files match ignore patterns" \
    $'.github/workflows/ci.yaml\n.upstream-sync-ignore\nhack/upstream-sync_test.sh\nOWNERS'
  assert_keep "7 - partially ignored PR is kept whole" $'.github/workflows/ci.yaml\nnew.txt'

  echo "All upstream sync tests passed"
}

# Remove the temporary repository unless explicitly preserved for debugging.
cleanup() {
  if [[ "${KEEP_TEST_REPO:-false}" == "true" ]]; then
    echo "Keeping temporary test repository: ${TEST_ROOT}"
    return
  fi
  rm -rf -- "$TEST_ROOT"
}

# Print a failure message and terminate the test.
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Create synthetic upstream and downstream Git history for the tests.
create_test_repository() {
  # Initialize an isolated repository for the test.
  cd -- "$TEST_ROOT" || fail "failed to enter temporary test repository"
  git init -q

  # Configure the identity.
  git config user.name "Upstream Sync Test"
  git config user.email "upstream-sync-test@example.com"

  # Create the common base commit shared by upstream and downstream.
  printf 'base\n' > existing.txt
  printf 'base\n' > deleted.txt
  git add existing.txt deleted.txt
  git commit -q -m "base"

  # Save the base SHA so the test can verify the merge-base calculation.
  local base_sha
  base_sha=$(git rev-parse HEAD)
  git update-ref refs/test/base "$base_sha"

  # Create the downstream state, where one upstream path was deleted.
  git checkout -q -b downstream-state
  git rm -q deleted.txt
  git commit -q -m "delete downstream-only path"

  # Expose the downstream commit through the ref used by the sync script.
  git update-ref refs/remotes/origin/main HEAD

  # Create the upstream state from the common base.
  git checkout -q -b upstream-state "$base_sha"
  printf 'updated upstream\n' > existing.txt
  printf 'updated upstream\n' > deleted.txt
  printf 'new upstream\n' > new.txt
  git add existing.txt deleted.txt new.txt
  git commit -q -m "upstream changes"

  # Expose the upstream commit through the ref used by the sync script.
  git update-ref refs/remotes/upstream/main HEAD

  # Use the repository's real ignore policy in the temporary test repository.
  cp "${SCRIPT_DIR}/../.upstream-sync-ignore" .upstream-sync-ignore
}

# Mock the GitHub CLI response with the configured changed-file list.
gh() {
  [[ "${1:-}" == "api" ]] || fail "unexpected gh command: $*"
  local paginate=false
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "--paginate" ]]; then
      paginate=true
      break
    fi
  done
  [[ "$paginate" == true ]] || fail "gh api call must be paginated"
  printf '%s\n' "$GH_CHANGED_FILES"
}

# Assert that a simulated PR is kept for synchronization.
assert_keep() {
  local description="$1"
  GH_CHANGED_FILES="$2"
  local reason
  if reason=$(should_skip_pr 1); then
    fail "${description}: unexpectedly skipped (${reason})"
  fi
  echo "PASS: ${description}"
}

# Assert that a simulated PR is skipped for the expected reason.
assert_skip() {
  local description="$1"
  local expected_reason="$2"
  GH_CHANGED_FILES="$3"
  local reason
  if ! reason=$(should_skip_pr 1); then
    fail "${description}: unexpectedly kept"
  fi
  [[ "$reason" == "$expected_reason" ]] || fail "${description}: unexpected reason (${reason})"
  echo "PASS: ${description}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_upstream_sync_tests "$@"
fi
