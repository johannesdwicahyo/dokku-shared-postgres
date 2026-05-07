#!/usr/bin/env bats
load test_helper

setup() {
  setup_plugin_env
  source "$REPO_ROOT/config"
  source "$REPO_ROOT/functions"
}

@test "service_size returns the byte count from pg_database_size" {
  stub_response psql '12345678'
  run service_size "demo"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "12345678" ]]
  assert_stub_called_with psql ".*pg_database_size.*demo.*"
}

@test "service_size strips whitespace from psql output" {
  stub_response psql '  42  '
  run service_size "demo"
  [[ "$output" == "42" ]]
}
