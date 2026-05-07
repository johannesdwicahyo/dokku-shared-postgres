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

@test "service_get_quota_mb returns default when no override" {
  run service_get_quota_mb "demo"
  [[ "$output" == "150" ]]
}

@test "service_get_quota_mb returns override when set" {
  printf '500' >"$PLUGIN_DATA_ROOT/demo/QUOTA_MB"
  run service_get_quota_mb "demo"
  [[ "$output" == "500" ]]
}

@test "service_set_quota_mb writes the file" {
  service_set_quota_mb "demo" "250"
  [[ "$(<"$PLUGIN_DATA_ROOT/demo/QUOTA_MB")" == "250" ]]
}

@test "service_set_quota_mb rejects non-numeric" {
  run service_set_quota_mb "demo" "huge"
  [[ "$status" -ne 0 ]]
}

@test "service_set_quota_mb rejects zero" {
  run service_set_quota_mb "demo" "0"
  [[ "$status" -ne 0 ]]
}

@test "service_set_quota_mb rejects negative" {
  run service_set_quota_mb "demo" "-5"
  [[ "$status" -ne 0 ]]
}

@test "service_unset_quota_mb removes override" {
  printf '500' >"$PLUGIN_DATA_ROOT/demo/QUOTA_MB"
  service_unset_quota_mb "demo"
  [[ ! -f "$PLUGIN_DATA_ROOT/demo/QUOTA_MB" ]]
}
