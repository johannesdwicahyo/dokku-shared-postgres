#!/usr/bin/env bats
load test_helper

setup() {
  setup_plugin_env
  source "$REPO_ROOT/config"
  source "$REPO_ROOT/functions"
}

@test "generate_password produces 32 hex chars" {
  run generate_password
  [[ "$status" -eq 0 ]]
  [[ "${#output}" -eq 32 ]]
  [[ "$output" =~ ^[a-f0-9]{32}$ ]]
}

@test "generate_password is non-deterministic" {
  a="$(generate_password)"
  b="$(generate_password)"
  [[ "$a" != "$b" ]]
}

@test "service_exists returns 1 when tenant dir is missing" {
  run service_exists "missing"
  [[ "$status" -eq 1 ]]
}

@test "service_exists returns 0 when tenant dir is present" {
  mkdir -p "$PLUGIN_DATA_ROOT/foo"
  run service_exists "foo"
  [[ "$status" -eq 0 ]]
}
