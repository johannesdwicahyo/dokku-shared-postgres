#!/usr/bin/env bash
# Sourced by every .bats file via `load test_helper`.

setup_plugin_env() {
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  export REPO_ROOT

  # Sandbox PLUGIN_DATA_ROOT into the per-test tmpdir.
  export PLUGIN_DATA_ROOT="$BATS_TEST_TMPDIR/data"
  mkdir -p "$PLUGIN_DATA_ROOT"

  # Stub bin must come first.
  export PATH="$REPO_ROOT/tests/bin:$PATH"

  # Stub I/O channels.
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  export STUB_RESPONSES_DIR="$BATS_TEST_TMPDIR/stub_responses"
  mkdir -p "$STUB_RESPONSES_DIR"
  : >"$STUB_LOG"

  # Make `psql` admin password lookup succeed by default.
  printf 'admin-pw\n' >"$BATS_TEST_TMPDIR/data/.admin_password"
  chmod 600 "$BATS_TEST_TMPDIR/data/.admin_password"
}

# Helper: queue a canned response for the next call to <stub_name>.
# Usage: stub_response docker '<container_id>'
stub_response() {
  local stub="$1" body="$2"
  printf '%s' "$body" >>"$STUB_RESPONSES_DIR/$stub.queue"
  printf '\n---END---\n' >>"$STUB_RESPONSES_DIR/$stub.queue"
}

# Helper: count how many times <stub_name> was invoked.
stub_call_count() {
  local stub="$1"
  grep -c "^${stub} " "$STUB_LOG" 2>/dev/null || true
}

# Helper: assert the most recent stub log line matches a regex.
assert_stub_called_with() {
  local stub="$1" regex="$2"
  local line
  line="$(grep "^${stub} " "$STUB_LOG" | tail -n1)"
  [[ "$line" =~ $regex ]] || {
    echo "stub $stub last call did not match: $regex"
    echo "actual: $line"
    return 1
  }
}
