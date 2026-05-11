#!/usr/bin/env bats
load test_helper

setup() {
  setup_plugin_env
  # Pretend the shared container is already running so ensure_shared_container short-circuits.
  stub_response docker 'dokku-shared-postgres'
}

@test "subcommands/create creates a tenant and prints the DSN" {
  run "$REPO_ROOT/subcommands/create" "shared-postgres:create" "demo"
  [[ "$status" -eq 0 ]]
  [[ -d "$PLUGIN_DATA_ROOT/demo" ]]
  [[ "$output" == *"postgres://demo_role:"* ]]
  [[ "$output" == *"@dokku-shared-postgres:5432/demo"* ]]
}

@test "subcommands/create exits non-zero on missing arg" {
  run "$REPO_ROOT/subcommands/create" "shared-postgres:create"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"name required"* ]]
}

@test "subcommands/create exits non-zero on invalid name" {
  run "$REPO_ROOT/subcommands/create" "shared-postgres:create" "BAD"
  [[ "$status" -ne 0 ]]
}
