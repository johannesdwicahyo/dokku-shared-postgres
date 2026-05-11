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

@test "validate_name accepts lowercase tenant" {
  run validate_name "myapp_db"
  [[ "$status" -eq 0 ]]
}

@test "validate_name rejects uppercase" {
  run validate_name "MyApp"
  [[ "$status" -ne 0 ]]
}

@test "validate_name rejects starting digit" {
  run validate_name "1foo"
  [[ "$status" -ne 0 ]]
}

@test "validate_name rejects empty" {
  run validate_name ""
  [[ "$status" -ne 0 ]]
}

@test "validate_name rejects names over 31 chars" {
  run validate_name "$(printf 'a%.0s' {1..32})"
  [[ "$status" -ne 0 ]]
}

@test "service_dsn assembles a postgres URL" {
  mkdir -p "$PLUGIN_DATA_ROOT/foo"
  printf 'foo_role'  >"$PLUGIN_DATA_ROOT/foo/ROLE"
  printf 'secret123' >"$PLUGIN_DATA_ROOT/foo/PASSWORD"
  printf 'foo'       >"$PLUGIN_DATA_ROOT/foo/DATABASE"
  run service_dsn "foo"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "postgres://foo_role:secret123@dokku-shared-postgres:5432/foo" ]]
}

@test "service_list emits one tenant per line" {
  mkdir -p "$PLUGIN_DATA_ROOT/alpha" "$PLUGIN_DATA_ROOT/beta"
  run service_list
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"alpha"* ]]
  [[ "$output" == *"beta"* ]]
}

@test "service_list ignores dotfiles" {
  mkdir -p "$PLUGIN_DATA_ROOT/alpha"
  : >"$PLUGIN_DATA_ROOT/.admin_password"
  run service_list
  [[ "$output" != *".admin_password"* ]]
}

@test "run_psql_admin invokes psql with admin password env and -d postgres" {
  run run_psql_admin "SELECT 1"
  [[ "$status" -eq 0 ]]
  assert_stub_called_with docker ".*psql.*-d postgres.*"
  assert_stub_called_with docker ".*psql.*-c SELECT 1.*"
}

@test "ensure_shared_container is a no-op when container is running" {
  stub_response docker 'dokku-shared-postgres'
  run ensure_shared_container
  [[ "$status" -eq 0 ]]
  run grep -c '^docker run ' "$STUB_LOG"
  [[ "$output" == "0" ]]
}

@test "ensure_shared_container starts container when missing" {
  stub_response docker ''
  stub_response docker ''
  stub_response docker ''
  run ensure_shared_container
  [[ "$status" -eq 0 ]]
  run grep -c '^docker run ' "$STUB_LOG"
  [[ "$output" -ge "1" ]]
}
