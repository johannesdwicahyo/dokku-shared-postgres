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

@test "subcommands/set-quota sets the cap" {
  run "$REPO_ROOT/subcommands/set-quota" "shared-postgres:set-quota" "demo" "300"
  [[ "$status" -eq 0 ]]
  [[ "$(<"$PLUGIN_DATA_ROOT/demo/QUOTA_MB")" == "300" ]]
}

@test "subcommands/set-quota errors on missing args" {
  run "$REPO_ROOT/subcommands/set-quota" "shared-postgres:set-quota" "demo"
  [[ "$status" -ne 0 ]]
}

@test "subcommands/set-quota errors on non-numeric" {
  run "$REPO_ROOT/subcommands/set-quota" "shared-postgres:set-quota" "demo" "huge"
  [[ "$status" -ne 0 ]]
}

@test "subcommands/unset-quota removes the cap" {
  printf '500' >"$PLUGIN_DATA_ROOT/demo/QUOTA_MB"
  run "$REPO_ROOT/subcommands/unset-quota" "shared-postgres:unset-quota" "demo"
  [[ "$status" -eq 0 ]]
  [[ ! -f "$PLUGIN_DATA_ROOT/demo/QUOTA_MB" ]]
}
