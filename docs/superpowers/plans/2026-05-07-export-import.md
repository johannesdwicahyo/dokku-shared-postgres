# `export` / `import` implementation plan

**Goal:** Round-trip backup of a tenant's data via `pg_dump` (export) and `psql` (import). Streams to stdout / from stdin so users can pipe directly to a file or restore command.

**Architecture:**
- `service_export <name>` runs `docker exec -i <container> pg_dump -U postgres <db>` and forwards stdout. Uses the admin role to ensure full access.
- `service_import <name>` reads stdin and pipes it to `docker exec -i <container> psql -U postgres -d <db>`. The tenant must exist (we don't auto-create).
- Subcommands `subcommands/export` and `subcommands/import` are thin CLI wrappers.

**Test approach:** the bats `docker` stub already logs invocations and supports canned stdout via `stub_response`. For `export` we queue the canned dump bytes and assert the subcommand's stdout matches. For `import` we feed test stdin and assert the docker stub saw `exec -i ... psql -U postgres -d <name>`.

**Out of scope:** scheduled backups, encryption, S3 upload. Operators wire those at the shell level (cron + s3cmd, restic, etc.).

---

## Tasks

### EI-1: `service_export` + `service_import` helpers (TDD)

**Files:** `functions`, `tests/export_import.bats`

#### Tests:

```bash
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
  run bash -c 'echo "x" | service_import ghost'
  # Note: service_import is sourced; running via bash -c won't share the function.
  # Replace with direct call:
  run service_import "ghost" <<<"x"
  [[ "$status" -ne 0 ]]
}

@test "service_import pipes stdin to psql via docker exec" {
  service_import "demo" <<<"CREATE TABLE t (id int);"
  assert_stub_called_with docker ".*exec -i.*dokku-shared-postgres.*psql -U postgres -d demo.*"
}
```

#### Implementation (append to `functions`):

```bash
service_export() {
  local name="$1"
  service_exists "$name" || { echo "service does not exist: $name" >&2; return 3; }
  local db
  db="$(<"$PLUGIN_DATA_ROOT/$name/DATABASE")"
  docker exec -i "$PLUGIN_CONTAINER_NAME" pg_dump -U postgres "$db"
}

service_import() {
  local name="$1"
  service_exists "$name" || { echo "service does not exist: $name" >&2; return 3; }
  local db
  db="$(<"$PLUGIN_DATA_ROOT/$name/DATABASE")"
  docker exec -i "$PLUGIN_CONTAINER_NAME" psql -U postgres -d "$db"
}
```

Note: pg_dump's authentication uses Postgres-side `pg_hba.conf` inside the container. Since we exec as the container's `postgres` OS user (default for docker exec when `-u` isn't passed), peer authentication on the local socket lets us in without a password. If pg_dump complains about needing a password in production, we'd add `-e PGPASSWORD=...` to the exec — but for v0.1 we trust the in-container peer auth.

Commit: `feat: add service_export and service_import helpers`

---

### EI-2: `subcommands/export` + `subcommands/import` (TDD)

**Files:** `subcommands/export`, `subcommands/import`, `tests/cmd_export_import.bats`

#### Tests:

```bash
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

@test "subcommands/export prints the dump on stdout" {
  stub_response docker '-- canned dump'
  run "$REPO_ROOT/subcommands/export" "demo"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "-- canned dump" ]]
}

@test "subcommands/export errors on missing arg" {
  run "$REPO_ROOT/subcommands/export"
  [[ "$status" -ne 0 ]]
}

@test "subcommands/export errors on missing tenant" {
  run "$REPO_ROOT/subcommands/export" "ghost"
  [[ "$status" -ne 0 ]]
}

@test "subcommands/import accepts stdin and invokes docker exec" {
  run "$REPO_ROOT/subcommands/import" "demo" <<<"-- restore"
  [[ "$status" -eq 0 ]]
  run grep -c '^docker exec -i' "$STUB_LOG"
  [[ "$output" -ge "1" ]]
}

@test "subcommands/import errors on missing arg" {
  run "$REPO_ROOT/subcommands/import"
  [[ "$status" -ne 0 ]]
}

@test "subcommands/import errors on missing tenant" {
  run "$REPO_ROOT/subcommands/import" "ghost" <<<"-- nope"
  [[ "$status" -ne 0 ]]
}
```

#### `subcommands/export`:

```bash
#!/usr/bin/env bash
set -euo pipefail
[[ "${DOKKU_TRACE:-}" == "1" ]] && set -x

PLUGIN_ROOT="$(cd "$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")" && pwd)"
# shellcheck source=config
source "$PLUGIN_ROOT/config"
# shellcheck source=functions
source "$PLUGIN_ROOT/functions"

name="${1:-}"
if [[ -z "$name" ]]; then
  echo "usage: dokku $PLUGIN_COMMAND_PREFIX:export <name> > backup.sql" >&2
  exit 2
fi

service_export "$name"
```

#### `subcommands/import`:

```bash
#!/usr/bin/env bash
set -euo pipefail
[[ "${DOKKU_TRACE:-}" == "1" ]] && set -x

PLUGIN_ROOT="$(cd "$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")" && pwd)"
# shellcheck source=config
source "$PLUGIN_ROOT/config"
# shellcheck source=functions
source "$PLUGIN_ROOT/functions"

name="${1:-}"
if [[ -z "$name" ]]; then
  echo "usage: dokku $PLUGIN_COMMAND_PREFIX:import <name> < backup.sql" >&2
  exit 2
fi

service_import "$name"
```

Commit: `feat: add export and import subcommands`

---

### EI-3: `commands` help + README

Add to help:
```
  $PLUGIN_COMMAND_PREFIX:export <name>           Stream pg_dump to stdout.
  $PLUGIN_COMMAND_PREFIX:import <name>           Pipe SQL on stdin to psql.
```

README "Usage" gains:
```bash
# Back up a tenant:
dokku shared-postgres:export myapp_db > backup.sql

# Restore from a backup (tenant must exist):
dokku shared-postgres:import myapp_db < backup.sql
```

Status line drops the "landing in v0.1" caveat — we now have everything in the v0.1.0 success criteria.

Commit: `docs: document export/import; v0.1.0-dev surface complete`

---

### EI-4: Final verification + push

- `make ci` green
- `git push -u origin feat/export-import`
