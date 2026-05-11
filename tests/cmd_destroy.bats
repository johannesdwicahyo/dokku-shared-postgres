#!/usr/bin/env bats
load test_helper

setup() {
  setup_plugin_env
  source "$REPO_ROOT/config"
  source "$REPO_ROOT/functions"
  stub_response docker 'dokku-shared-postgres'
  service_create "demo"
  : >"$STUB_LOG"
}

@test "subcommands/destroy with -f removes the tenant non-interactively" {
  run "$REPO_ROOT/subcommands/destroy" "shared-postgres:destroy" "demo" "-f"
  [[ "$status" -eq 0 ]]
  [[ ! -d "$PLUGIN_DATA_ROOT/demo" ]]
}

@test "subcommands/destroy refuses without -f" {
  run "$REPO_ROOT/subcommands/destroy" "shared-postgres:destroy" "demo"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"-f"* ]]
  [[ -d "$PLUGIN_DATA_ROOT/demo" ]]
}

@test "subcommands/destroy errors on missing tenant" {
  run "$REPO_ROOT/subcommands/destroy" "shared-postgres:destroy" "ghost" "-f"
  [[ "$status" -ne 0 ]]
}
