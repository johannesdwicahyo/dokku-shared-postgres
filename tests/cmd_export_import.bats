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

@test "subcommands/export prints the dump on stdout" {
  stub_response docker '-- canned dump'
  run "$REPO_ROOT/subcommands/export" "shared-postgres:export" "demo"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "-- canned dump" ]]
}

@test "subcommands/export errors on missing arg" {
  run "$REPO_ROOT/subcommands/export" "shared-postgres:export"
  [[ "$status" -ne 0 ]]
}

@test "subcommands/export errors on missing tenant" {
  run "$REPO_ROOT/subcommands/export" "shared-postgres:export" "ghost"
  [[ "$status" -ne 0 ]]
}

@test "subcommands/import accepts stdin and invokes docker exec" {
  run "$REPO_ROOT/subcommands/import" "shared-postgres:import" "demo" <<<"-- restore"
  [[ "$status" -eq 0 ]]
  run grep -c '^docker exec -i' "$STUB_LOG"
  [[ "$output" -ge "1" ]]
}

@test "subcommands/import errors on missing arg" {
  run "$REPO_ROOT/subcommands/import" "shared-postgres:import"
  [[ "$status" -ne 0 ]]
}

@test "subcommands/import errors on missing tenant" {
  run "$REPO_ROOT/subcommands/import" "shared-postgres:import" "ghost" <<<"-- nope"
  [[ "$status" -ne 0 ]]
}
