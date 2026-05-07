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

@test "service_export errors when tenant is missing" {
  run service_export "ghost"
  [[ "$status" -ne 0 ]]
}

@test "service_export streams pg_dump stdout via docker exec" {
  stub_response docker '-- canned dump body'
  run service_export "demo"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "-- canned dump body" ]]
  assert_stub_called_with docker ".*exec -i.*dokku-shared-postgres.*pg_dump -U postgres demo.*"
}

@test "service_import errors when tenant is missing" {
  run service_import "ghost" <<<"x"
  [[ "$status" -ne 0 ]]
}

@test "service_import pipes stdin to psql via docker exec" {
  service_import "demo" <<<"CREATE TABLE t (id int);"
  assert_stub_called_with docker ".*exec -i.*dokku-shared-postgres.*psql -U postgres -d demo.*"
}
