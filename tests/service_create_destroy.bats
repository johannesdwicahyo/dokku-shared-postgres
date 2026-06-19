#!/usr/bin/env bats
load test_helper

setup() {
  setup_plugin_env
  source "$REPO_ROOT/config"
  source "$REPO_ROOT/functions"
  # Pretend the shared container is already running so ensure_shared_container short-circuits.
  stub_response docker 'dokku-shared-postgres'
}

@test "service_create writes metadata files" {
  service_create "demo"
  [[ -f "$PLUGIN_DATA_ROOT/demo/PASSWORD" ]]
  [[ -f "$PLUGIN_DATA_ROOT/demo/ROLE" ]]
  [[ -f "$PLUGIN_DATA_ROOT/demo/DATABASE" ]]
  [[ "$(<"$PLUGIN_DATA_ROOT/demo/ROLE")" == "demo_role" ]]
  [[ "$(<"$PLUGIN_DATA_ROOT/demo/DATABASE")" == "demo" ]]
  pw="$(<"$PLUGIN_DATA_ROOT/demo/PASSWORD")"
  [[ "${#pw}" -eq 32 ]]
}

@test "service_create issues CREATE ROLE then CREATE DATABASE then GRANT" {
  service_create "demo"
  # All psql calls — order matters.
  sql_calls=()
  while IFS= read -r line; do sql_calls+=("$line"); done < <(grep '^docker exec.*psql' "$STUB_LOG")
  [[ "${sql_calls[0]}" == *"CREATE ROLE"* ]]
  [[ "${sql_calls[0]}" == *"demo_role"* ]]
  [[ "${sql_calls[0]}" == *"CONNECTION LIMIT 40"* ]]
  [[ "${sql_calls[1]}" == *"CREATE DATABASE"* ]]
  [[ "${sql_calls[1]}" == *"OWNER demo_role"* ]]
  [[ "${sql_calls[2]}" == *"REVOKE"* ]]
  [[ "${sql_calls[2]}" == *"PUBLIC"* ]]
}

@test "service_create refuses an existing tenant" {
  service_create "demo"
  run service_create "demo"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"already exists"* ]]
}

@test "service_create rejects invalid name" {
  run service_create "BadName"
  [[ "$status" -ne 0 ]]
}

@test "service_destroy issues DROP DATABASE then DROP ROLE and removes data dir" {
  service_create "demo"
  : >"$STUB_LOG"   # reset log so we only inspect destroy calls
  service_destroy "demo"
  [[ ! -d "$PLUGIN_DATA_ROOT/demo" ]]
  sql_calls=()
  while IFS= read -r line; do sql_calls+=("$line"); done < <(grep '^docker exec.*psql' "$STUB_LOG")
  [[ "${sql_calls[0]}" == *"DROP DATABASE"* ]]
  [[ "${sql_calls[0]}" == *"demo"* ]]
  [[ "${sql_calls[1]}" == *"DROP ROLE"* ]]
  [[ "${sql_calls[1]}" == *"demo_role"* ]]
}

@test "service_destroy is idempotent when tenant is missing" {
  run service_destroy "ghost"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"does not exist"* ]]
}
