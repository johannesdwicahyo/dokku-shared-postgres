#!/usr/bin/env bats
load test_helper

setup() {
  setup_plugin_env
  mkdir -p "$PLUGIN_DATA_ROOT/alpha" "$PLUGIN_DATA_ROOT/beta"
}

@test "subcommands/list prints tenants alphabetically" {
  run "$REPO_ROOT/subcommands/list" "shared-postgres:list"
  [[ "$status" -eq 0 ]]
  expected=$'alpha\nbeta'
  [[ "$output" == "$expected" ]]
}

@test "subcommands/list prints nothing when empty" {
  rm -rf "${PLUGIN_DATA_ROOT:?}/"*
  run "$REPO_ROOT/subcommands/list" "shared-postgres:list"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}
