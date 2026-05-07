#!/usr/bin/env bats
load test_helper

setup() {
  setup_plugin_env
  source "$REPO_ROOT/config"
  source "$REPO_ROOT/functions"

  # Pre-create a tenant the unsanitary way (avoids docker stub interaction).
  mkdir -p "$PLUGIN_DATA_ROOT/demo"
  printf 'demo_role' >"$PLUGIN_DATA_ROOT/demo/ROLE"
  printf 'pw'        >"$PLUGIN_DATA_ROOT/demo/PASSWORD"
  printf 'demo'      >"$PLUGIN_DATA_ROOT/demo/DATABASE"
  : >"$PLUGIN_DATA_ROOT/demo/LINKS"
}

@test "service_link sets DATABASE_URL on the app" {
  service_link "demo" "myapp"
  assert_stub_called_with dokku "config:set --no-restart myapp DATABASE_URL=postgres://demo_role:pw@dokku-shared-postgres:5432/demo"
}

@test "service_link records the app in LINKS" {
  service_link "demo" "myapp"
  run cat "$PLUGIN_DATA_ROOT/demo/LINKS"
  [[ "$output" == "myapp" ]]
}

@test "service_link is idempotent (no duplicate LINKS entries)" {
  service_link "demo" "myapp"
  service_link "demo" "myapp"
  run grep -c '^myapp$' "$PLUGIN_DATA_ROOT/demo/LINKS"
  [[ "$output" == "1" ]]
}

@test "service_link errors when tenant is missing" {
  run service_link "ghost" "myapp"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"does not exist"* ]]
}

@test "service_link errors when app is empty" {
  run service_link "demo" ""
  [[ "$status" -ne 0 ]]
}
