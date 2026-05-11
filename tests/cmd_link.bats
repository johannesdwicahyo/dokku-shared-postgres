#!/usr/bin/env bats
load test_helper

setup() {
  setup_plugin_env
  source "$REPO_ROOT/config"
  source "$REPO_ROOT/functions"
  mkdir -p "$PLUGIN_DATA_ROOT/demo"
  printf 'demo_role' >"$PLUGIN_DATA_ROOT/demo/ROLE"
  printf 'pw'        >"$PLUGIN_DATA_ROOT/demo/PASSWORD"
  printf 'demo'      >"$PLUGIN_DATA_ROOT/demo/DATABASE"
  : >"$PLUGIN_DATA_ROOT/demo/LINKS"
}

@test "subcommands/link calls dokku config:set" {
  run "$REPO_ROOT/subcommands/link" "shared-postgres:link" "demo" "myapp"
  [[ "$status" -eq 0 ]]
  run grep '^dokku ' "$STUB_LOG"
  [[ "$output" == *"config:set"* ]]
  [[ "$output" == *"DATABASE_URL=postgres://demo_role:pw@dokku-shared-postgres:5432/demo"* ]]
}

@test "subcommands/link errors on missing args" {
  run "$REPO_ROOT/subcommands/link" "shared-postgres:link" "demo"
  [[ "$status" -ne 0 ]]
}
