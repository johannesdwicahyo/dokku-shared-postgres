#!/usr/bin/env bats
load test_helper

setup() {
  setup_plugin_env
  source "$REPO_ROOT/config"
  source "$REPO_ROOT/functions"
}

@test "service_size returns the byte count from pg_database_size" {
  stub_response docker '12345678'
  run service_size "demo"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "12345678" ]]
  assert_stub_called_with docker ".*psql.*pg_database_size.*demo.*"
}

@test "service_size strips whitespace from psql output" {
  stub_response docker '  42  '
  run service_size "demo"
  [[ "$output" == "42" ]]
}

@test "service_info errors when tenant is missing" {
  run service_info "ghost"
  [[ "$status" -ne 0 ]]
}

@test "service_info returns key=value lines for an existing tenant" {
  mkdir -p "$PLUGIN_DATA_ROOT/demo"
  printf 'demo_role'   >"$PLUGIN_DATA_ROOT/demo/ROLE"
  printf 'pw'          >"$PLUGIN_DATA_ROOT/demo/PASSWORD"
  printf 'demo'        >"$PLUGIN_DATA_ROOT/demo/DATABASE"
  printf 'app1\napp2\n' >"$PLUGIN_DATA_ROOT/demo/LINKS"

  stub_response docker '4096'
  stub_response docker '3'

  run service_info "demo"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"name=demo"* ]]
  [[ "$output" == *"role=demo_role"* ]]
  [[ "$output" == *"database=demo"* ]]
  [[ "$output" == *"host=dokku-shared-postgres"* ]]
  [[ "$output" == *"port=5432"* ]]
  [[ "$output" == *"size_bytes=4096"* ]]
  [[ "$output" == *"active_connections=3"* ]]
  [[ "$output" == *"linked_apps=app1,app2"* ]]
}

@test "service_info reports empty linked_apps when LINKS is empty" {
  mkdir -p "$PLUGIN_DATA_ROOT/demo"
  printf 'demo_role' >"$PLUGIN_DATA_ROOT/demo/ROLE"
  printf 'pw'        >"$PLUGIN_DATA_ROOT/demo/PASSWORD"
  printf 'demo'      >"$PLUGIN_DATA_ROOT/demo/DATABASE"
  : >"$PLUGIN_DATA_ROOT/demo/LINKS"

  stub_response docker '0'
  stub_response docker '0'
  run service_info "demo"
  [[ "$output" == *"linked_apps="* ]]
  [[ "$output" != *"linked_apps=,"* ]]
}
