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
  stub_response docker '8192'
  stub_response docker '0'
}

@test "subcommands/info prints labelled lines" {
  run "$REPO_ROOT/subcommands/info" "shared-postgres:info" "demo"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Name:"* ]]
  [[ "$output" == *"demo"* ]]
  [[ "$output" == *"Role:"* ]]
  [[ "$output" == *"demo_role"* ]]
  [[ "$output" == *"Size:"* ]]
  [[ "$output" == *"8192"* ]]
}

@test "subcommands/info errors on missing arg" {
  run "$REPO_ROOT/subcommands/info" "shared-postgres:info"
  [[ "$status" -ne 0 ]]
}

@test "subcommands/info errors on missing tenant" {
  run "$REPO_ROOT/subcommands/info" "shared-postgres:info" "ghost"
  [[ "$status" -ne 0 ]]
}
