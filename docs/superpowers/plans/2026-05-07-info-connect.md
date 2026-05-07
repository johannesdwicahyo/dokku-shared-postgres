# `info` + `connect` Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development. Steps use `- [ ]` checkboxes.

**Goal:** Add the read-only `shared-postgres:info <name>` and `shared-postgres:connect <name>` subcommands. Adds two `functions` helpers (`service_size`, `service_info`) plus two new subcommand scripts.

**Architecture:** `info` uses `run_psql_admin` to query `pg_database_size` and `pg_stat_activity` for live size/connection info, then merges with metadata-file fields. `connect` resolves the tenant's role + database and execs `docker exec -it <container> psql ...` so the user lands in psql as that tenant. A `--print-only` flag prints the command without exec'ing, enabling bats tests without a live container.

**Stack:** Same as previous plan — Bash 5, bats-core, ShellCheck. Continues feat branch `feat/info-connect` (already created off `feat/scaffold-create-destroy-link`).

**Out of scope:** the periodic quota-check trigger, `set-quota`, `export`/`import`. Those are separate plans.

---

## File Structure

| Path | Status | Responsibility |
|---|---|---|
| `functions` | modify | Append `service_size`, `service_info`. |
| `subcommands/info` | create | CLI: print tenant summary (role, db, dsn-redacted, size, links, conns). |
| `subcommands/connect` | create | CLI: `docker exec -it` into shared container as tenant role; `--print-only` for tests. |
| `tests/functions_info.bats` | create | TDD for `service_size` + `service_info`. |
| `tests/cmd_info.bats` | create | TDD for `subcommands/info`. |
| `tests/cmd_connect.bats` | create | TDD for `subcommands/connect` (uses `--print-only`). |
| `commands` | modify | Add `info` + `connect` lines to the help block. |
| `README.md` | modify | Mention `info` + `connect` in usage. |

---

## Task 1: `service_size` helper (TDD)

**Files:** `functions`, `tests/functions_info.bats`

- [ ] **Step 1: Write failing test**

`tests/functions_info.bats`:

```bash
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
```

- [ ] **Step 2: Run, confirm failure**

`bats tests/functions_info.bats` → 2 fail.

- [ ] **Step 3: Append to `functions`**

```bash
service_size() {
  local name="$1"
  local raw
  raw="$(run_psql_admin "SELECT pg_database_size('$name');" -t -A 2>/dev/null || true)"
  # Trim whitespace.
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  printf '%s\n' "$raw"
}
```

Note: `run_psql_admin` already takes a single SQL string. We need it to also accept extra `psql` flags so `-t -A` can suppress headers and column separators. Update `run_psql_admin` signature accordingly:

Currently:
```bash
run_psql_admin() {
  local sql="$1"
  ...
  PGPASSWORD="$pw" psql ... -c "$sql"
}
```

Change to:
```bash
run_psql_admin() {
  local sql="$1"
  shift || true
  local pw
  pw="$(<"$PLUGIN_ADMIN_PASSWORD_FILE")"
  PGPASSWORD="$pw" psql \
    -h "$PLUGIN_CONTAINER_NAME" \
    -p "$PLUGIN_DB_PORT" \
    -U postgres \
    -d postgres \
    -v ON_ERROR_STOP=1 \
    "$@" \
    -c "$sql"
}
```

This is backward-compatible: existing callers pass one arg and the extra `"$@"` is empty.

- [ ] **Step 4: Run all bats — should be 38 (36 prior + 2 new)**

`bats tests/`. All previous tests still pass because the change is additive.

- [ ] **Step 5: ShellCheck**

`shellcheck -x functions config tests/test_helper.bash`

- [ ] **Step 6: Commit**

`git add functions tests/functions_info.bats && git commit -m "feat: add service_size helper and extend run_psql_admin with extra args"`

---

## Task 2: `service_info` helper (TDD)

**Files:** `functions`, `tests/functions_info.bats`

`service_info` returns a multi-line key=value blob suitable for `subcommands/info` to format. We don't return JSON because the consumer is a bash script — newline-delimited K=V is simpler.

Output keys (one per line):
- `name=<name>`
- `role=<role>`
- `database=<db>`
- `host=<container>`
- `port=<port>`
- `size_bytes=<size>` (or empty if pg unreachable)
- `connection_limit=<int>` (default 20; for v0.1.0 always the default)
- `active_connections=<int>` (or empty if pg unreachable)
- `linked_apps=<comma,separated>` (empty if none)

- [ ] **Step 1: Failing tests**

Append to `tests/functions_info.bats`:

```bash
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

  # First psql call (size), second (active conns).
  stub_response psql '4096'
  stub_response psql '3'

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

  stub_response psql '0'
  stub_response psql '0'
  run service_info "demo"
  [[ "$output" == *"linked_apps="* ]]
  [[ "$output" != *"linked_apps=,"* ]]
}
```

- [ ] **Step 2: Run, confirm failure**

`bats tests/functions_info.bats` → new tests fail.

- [ ] **Step 3: Append to `functions`**

```bash
service_active_connections() {
  local name="$1"
  local raw
  raw="$(run_psql_admin "SELECT count(*) FROM pg_stat_activity WHERE datname='$name';" -t -A 2>/dev/null || true)"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  printf '%s\n' "$raw"
}

service_info() {
  local name="$1"
  if ! service_exists "$name"; then
    echo "service does not exist: $name" >&2
    return 3
  fi

  local role db size conns links_csv
  role="$(<"$PLUGIN_DATA_ROOT/$name/ROLE")"
  db="$(<"$PLUGIN_DATA_ROOT/$name/DATABASE")"
  size="$(service_size "$name")"
  conns="$(service_active_connections "$name")"

  if [[ -s "$PLUGIN_DATA_ROOT/$name/LINKS" ]]; then
    links_csv="$(tr '\n' ',' <"$PLUGIN_DATA_ROOT/$name/LINKS")"
    links_csv="${links_csv%,}"
  else
    links_csv=""
  fi

  printf 'name=%s\n'                "$name"
  printf 'role=%s\n'                "$role"
  printf 'database=%s\n'            "$db"
  printf 'host=%s\n'                "$PLUGIN_CONTAINER_NAME"
  printf 'port=%s\n'                "$PLUGIN_DB_PORT"
  printf 'size_bytes=%s\n'          "$size"
  printf 'connection_limit=%s\n'    "$PLUGIN_DEFAULT_CONNECTION_LIMIT"
  printf 'active_connections=%s\n'  "$conns"
  printf 'linked_apps=%s\n'         "$links_csv"
}
```

- [ ] **Step 4: Run, all pass**

- [ ] **Step 5: ShellCheck + commit**

`shellcheck -x functions config tests/test_helper.bash`
`git add functions tests/functions_info.bats && git commit -m "feat: add service_info helper"`

---

## Task 3: `subcommands/info` (TDD)

**Files:** `subcommands/info`, `tests/cmd_info.bats`

Pretty-prints `service_info` output as a human-readable table-ish blob.

- [ ] **Step 1: Failing tests**

`tests/cmd_info.bats`:

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
  stub_response psql '8192'   # size
  stub_response psql '0'      # conns
}

@test "subcommands/info prints labelled lines" {
  run "$REPO_ROOT/subcommands/info" "demo"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Name:"* ]]
  [[ "$output" == *"demo"* ]]
  [[ "$output" == *"Role:"* ]]
  [[ "$output" == *"demo_role"* ]]
  [[ "$output" == *"Size:"* ]]
  [[ "$output" == *"8192"* ]]
}

@test "subcommands/info errors on missing arg" {
  run "$REPO_ROOT/subcommands/info"
  [[ "$status" -ne 0 ]]
}

@test "subcommands/info errors on missing tenant" {
  run "$REPO_ROOT/subcommands/info" "ghost"
  [[ "$status" -ne 0 ]]
}
```

- [ ] **Step 2: Implement `subcommands/info`**

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
  echo "usage: dokku $PLUGIN_COMMAND_PREFIX:info <name>" >&2
  exit 2
fi

# Read service_info into a key=value map and pretty-print.
declare -A info=()
while IFS='=' read -r key value; do
  [[ -z "$key" ]] && continue
  info["$key"]="$value"
done < <(service_info "$name")

printf '%-22s %s\n' "Name:"               "${info[name]}"
printf '%-22s %s\n' "Role:"               "${info[role]}"
printf '%-22s %s\n' "Database:"           "${info[database]}"
printf '%-22s %s:%s\n' "Host:"            "${info[host]}" "${info[port]}"
printf '%-22s %s\n' "Size:"               "${info[size_bytes]} bytes"
printf '%-22s %s / %s\n' "Connections:"   "${info[active_connections]}" "${info[connection_limit]}"
printf '%-22s %s\n' "Linked apps:"        "${info[linked_apps]:-(none)}"
```

`chmod +x subcommands/info`

- [ ] **Step 3: Run, all pass**

- [ ] **Step 4: Commit**

`git add subcommands/info tests/cmd_info.bats && git commit -m "feat: add shared-postgres:info subcommand"`

---

## Task 4: `subcommands/connect` with `--print-only` (TDD)

**Files:** `subcommands/connect`, `tests/cmd_connect.bats`

The actual `connect` flow execs `docker exec -it <container> psql -U <role> -d <db>` after sourcing `PGPASSWORD` from the tenant's password file. For tests, `--print-only` prints the command line that would be exec'd and exits 0.

- [ ] **Step 1: Failing tests**

`tests/cmd_connect.bats`:

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

@test "subcommands/connect --print-only emits docker exec line" {
  run "$REPO_ROOT/subcommands/connect" "demo" "--print-only"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"docker exec"* ]]
  [[ "$output" == *"-it"* ]]
  [[ "$output" == *"dokku-shared-postgres"* ]]
  [[ "$output" == *"psql"* ]]
  [[ "$output" == *"-U demo_role"* ]]
  [[ "$output" == *"-d demo"* ]]
}

@test "subcommands/connect --print-only does not include the password literal" {
  run "$REPO_ROOT/subcommands/connect" "demo" "--print-only"
  [[ "$output" != *"pw"* ]] || [[ "$output" == *"PGPASSWORD=<redacted>"* ]]
}

@test "subcommands/connect errors on missing tenant" {
  run "$REPO_ROOT/subcommands/connect" "ghost" "--print-only"
  [[ "$status" -ne 0 ]]
}

@test "subcommands/connect errors on missing arg" {
  run "$REPO_ROOT/subcommands/connect"
  [[ "$status" -ne 0 ]]
}
```

The second test guards against accidentally leaking the password into the printed command — we want the env var visible (`PGPASSWORD=<redacted>` or omitted from the print) but NOT the literal `pw`.

- [ ] **Step 2: Implement `subcommands/connect`**

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
flag="${2:-}"
if [[ -z "$name" ]]; then
  echo "usage: dokku $PLUGIN_COMMAND_PREFIX:connect <name>" >&2
  exit 2
fi
if ! service_exists "$name"; then
  echo "service does not exist: $name" >&2
  exit 3
fi

role="$(<"$PLUGIN_DATA_ROOT/$name/ROLE")"
db="$(<"$PLUGIN_DATA_ROOT/$name/DATABASE")"
pw="$(<"$PLUGIN_DATA_ROOT/$name/PASSWORD")"

if [[ "$flag" == "--print-only" ]]; then
  printf 'PGPASSWORD=<redacted> docker exec -it -e PGPASSWORD %s psql -U %s -d %s\n' \
    "$PLUGIN_CONTAINER_NAME" "$role" "$db"
  exit 0
fi

PGPASSWORD="$pw" exec docker exec -it \
  -e PGPASSWORD \
  "$PLUGIN_CONTAINER_NAME" \
  psql -U "$role" -d "$db"
```

`chmod +x subcommands/connect`

- [ ] **Step 3: Run all bats, all pass**

- [ ] **Step 4: ShellCheck + commit**

`shellcheck -x subcommands/info subcommands/connect`
`git add subcommands/connect tests/cmd_connect.bats && git commit -m "feat: add shared-postgres:connect subcommand"`

---

## Task 5: Update `commands` help block

**Files:** `commands`

- [ ] **Step 1: Edit help block to add info + connect lines**

After the existing `list` line, add:

```
  $PLUGIN_COMMAND_PREFIX:info <name>             Print tenant details (role, db, size, conns, links).
  $PLUGIN_COMMAND_PREFIX:connect <name>          Open psql as the tenant role (interactive).
```

- [ ] **Step 2: Verify dispatch still works**

Run `bats tests/` — full suite green.

- [ ] **Step 3: ShellCheck + commit**

`shellcheck -x commands`
`git add commands && git commit -m "docs: list info+connect in help output"`

---

## Task 6: README pass

**Files:** `README.md`

- [ ] **Step 1: Add info + connect to the Usage section**

Insert between the `:list` and `:destroy` examples:

```bash
# Inspect a tenant (size, active connections, linked apps):
dokku shared-postgres:info myapp_db

# Open an interactive psql session as the tenant role:
dokku shared-postgres:connect myapp_db
```

Also update the status banner: drop the explicit list of "shipping CLI surface" since it now matches the documented commands.

- [ ] **Step 2: Commit**

`git add README.md && git commit -m "docs: add info+connect usage examples"`

---

## Task 7: Final verification

- [ ] `make ci` — all green
- [ ] `bats tests/` — count = 36 (prior) + 2 (size) + 2 (info helper) + 1 (info empty links) + 3 (cmd_info) + 4 (cmd_connect) = **48**
- [ ] All subcommand scripts executable
- [ ] Push: `git push -u origin feat/info-connect`

---

## Self-review

- **Coverage of stated goal:** info + connect + list polish. List polish was scoped down — `list` already emits one tenant per line which is the right primitive; richer output belongs in `info`. No changes to `list` in this plan.
- **Type/name consistency:** `service_info`, `service_size`, `service_active_connections` follow the `service_*` convention used previously. `subcommands/info` uses bash 4 associative arrays (`declare -A`) — flag if macOS bash 3.2 is the local target. CI runs on Ubuntu 24.04 (bash 5+) so it's fine for CI; for local dev on macOS, devs need bash from brew (most do).
- **Bash 3.2 caveat for `subcommands/info`:** macOS bash 3.2 doesn't support `declare -A`. If local-dev compatibility matters, fall back to a `case` over while-read keys. This is flagged in Task 3; the subagent should confirm the local test passes — if not, use the fallback.
- **Password leakage:** `subcommands/connect` `--print-only` deliberately replaces the password with `<redacted>` so test assertions work and we don't accidentally log secrets. Real exec passes `PGPASSWORD` via env, never on the command line.
