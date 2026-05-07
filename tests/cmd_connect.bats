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

@test "subcommands/connect --print-only emits docker exec line" {
  run "$REPO_ROOT/subcommands/connect" "demo" "--print-only"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"docker exec"* ]]
  [[ "$output" == *"-it"* ]]
  [[ "$output" == *"dokku-shared-postgres"* ]]
  [[ "$output" == *"psql"* ]]
  [[ "$output" == *"-U demo_role"* ]]
  [[ "$output" == *"-d demo"* ]]
}

@test "subcommands/connect --print-only redacts the password" {
  run "$REPO_ROOT/subcommands/connect" "demo" "--print-only"
  [[ "$output" == *"PGPASSWORD=<redacted>"* ]]
  [[ "$output" != *"PGPASSWORD=pw"* ]]
}

@test "subcommands/connect errors on missing tenant" {
  run "$REPO_ROOT/subcommands/connect" "ghost" "--print-only"
  [[ "$status" -ne 0 ]]
}

@test "subcommands/connect errors on missing arg" {
  run "$REPO_ROOT/subcommands/connect"
  [[ "$status" -ne 0 ]]
}
