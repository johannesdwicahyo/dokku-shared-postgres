#!/usr/bin/env bats
load test_helper

setup() {
  setup_plugin_env
  source "$REPO_ROOT/config"
  source "$REPO_ROOT/functions"
  for n in alpha beta; do
    mkdir -p "$PLUGIN_DATA_ROOT/$n"
    printf '%s_role' "$n" >"$PLUGIN_DATA_ROOT/$n/ROLE"
    printf 'pw'           >"$PLUGIN_DATA_ROOT/$n/PASSWORD"
    printf '%s' "$n"      >"$PLUGIN_DATA_ROOT/$n/DATABASE"
    : >"$PLUGIN_DATA_ROOT/$n/LINKS"
  done
}

@test "check-quotas runs across all tenants and exits 0 when all under cap" {
  stub_response psql '0'
  stub_response psql '0'
  run "$REPO_ROOT/subcommands/check-quotas"
  [[ "$status" -eq 0 ]]
}

@test "check-quotas reports flipped state when a tenant exceeds cap" {
  printf '1' >"$PLUGIN_DATA_ROOT/alpha/QUOTA_MB"
  stub_response psql '2097152'
  stub_response psql ''
  stub_response psql '0'
  run "$REPO_ROOT/subcommands/check-quotas"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"flipped"* ]]
  [[ "$output" == *"alpha"* ]]
}

@test "check-quotas does nothing when no tenants" {
  rm -rf "$PLUGIN_DATA_ROOT"/*
  run "$REPO_ROOT/subcommands/check-quotas"
  [[ "$status" -eq 0 ]]
}
