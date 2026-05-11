#!/usr/bin/env bats
load test_helper

setup() {
  setup_plugin_env
}

@test "subcommands/help prints usage with all subcommands" {
  run "$REPO_ROOT/subcommands/help" "shared-postgres:help"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Usage: dokku shared-postgres:"* ]]
  for cmd in create destroy link list info connect set-quota unset-quota check-quotas export import help; do
    [[ "$output" == *"shared-postgres:$cmd"* ]] || {
      echo "missing command in help output: $cmd"
      return 1
    }
  done
}

@test "commands dispatcher routes :help to subcommands/help" {
  run "$REPO_ROOT/commands" "shared-postgres:help"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Usage: dokku shared-postgres:"* ]]
}
