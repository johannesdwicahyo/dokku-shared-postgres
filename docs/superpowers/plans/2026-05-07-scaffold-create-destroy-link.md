# Scaffold + create/destroy/link Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the `dokku-shared-postgres` plugin scaffold and ship the four foundational subcommands — `create`, `destroy`, `link`, and a minimal `list` (needed by `link`/tests) — with bats unit tests using stubbed `docker` and `psql`. No live Dokku host is required this session.

**Architecture:** Bash plugin following the `dokku/dokku-postgres` layout. One shared `postgres:16-alpine` container managed by the plugin; tenants are Postgres ROLE + DATABASE pairs with random passwords. Per-tenant metadata persists under `$PLUGIN_DATA_ROOT/<name>/`. `link` writes `DATABASE_URL` on the target Dokku app via `dokku config:set`.

**Tech Stack:** Bash 5 (`set -euo pipefail`), `bats-core` for tests, `shellcheck` for static analysis, GitHub Actions for CI. No runtime languages other than Bash; tests stub `docker`/`psql`/`dokku` via a PATH-prefixed `tests/bin/` directory.

**Out of scope this session** (follow-up plans will cover): `info`, `connect`, `expose`, `promote`, `export`, `import`, `set-quota`, the periodic quota-check trigger, the `pre-install` hook proper, GitHub release workflow, integration tests against a live Dokku host.

---

## File Structure

Files this plan will create or touch (relative to repo root):

| Path | Responsibility |
|---|---|
| `plugin.toml` | Plugin metadata (already exists; updated to include final name + description). |
| `config` | Defines `PLUGIN_*` env vars (command prefix, image, data root, network name, defaults). Sourced by every other script. |
| `commands` | Dispatcher — Dokku invokes this with the user's args; routes to `subcommands/<name>`. |
| `functions` | Shared bash helpers: `ensure_shared_container`, `run_psql_admin`, `generate_password`, `service_exists`, `service_create`, `service_destroy`, `service_link`, `service_dsn`, `service_list`. |
| `install` | First-time setup: ensure data root, ensure network, pull image, start shared container, init admin password. Re-run-safe (idempotent). |
| `subcommands/create` | Validates name, calls `service_create`. |
| `subcommands/destroy` | Validates name, prompts for confirmation, calls `service_destroy`. |
| `subcommands/link` | Validates name + app, calls `service_link` (which calls `dokku config:set`). |
| `subcommands/list` | Calls `service_list`; prints one tenant per line. |
| `tests/test_helper.bash` | Common setup: builds isolated `BATS_TEST_TMPDIR`, exports stubbed `PLUGIN_DATA_ROOT`, prepends `tests/bin/` to PATH. |
| `tests/bin/docker` | Stub. Logs invocation to `$STUB_LOG`; reads canned responses from `$STUB_RESPONSES_DIR`. |
| `tests/bin/psql` | Stub. Same model as `docker` stub. |
| `tests/bin/dokku` | Stub. Same model. Used by `link` tests. |
| `tests/create.bats` | Tests for `subcommands/create`. |
| `tests/destroy.bats` | Tests for `subcommands/destroy`. |
| `tests/link.bats` | Tests for `subcommands/link`. |
| `tests/list.bats` | Tests for `subcommands/list`. |
| `tests/functions.bats` | Direct unit tests for `functions` helpers. |
| `.github/workflows/ci.yml` | ShellCheck + bats matrix. |
| `Makefile` | `make test`, `make lint`, `make ci` convenience targets. |
| `README.md` | Update install + usage docs to reflect the four shipping subcommands. |

Every script begins with `#!/usr/bin/env bash` and `set -euo pipefail`. Every `.bats` test file enables `bats_load_library bats-support bats-assert` if available, but falls back to plain bats assertions to keep CI minimal.

---

## Conventions used by every task

- Repo root in commands below: assume `cwd` is repo root.
- All bash files are 2-space indented, `shellcheck`-clean (`shellcheck -x <file>`).
- `PLUGIN_COMMAND_PREFIX="shared-postgres"` everywhere.
- Tenant names must match `^[a-z][a-z0-9_-]{0,30}$`. (Postgres identifier rules + Dokku app name conservatism.)
- Tenant role name = `<name>_role`. Tenant database name = `<name>`.
- Per-tenant metadata files (created during `service_create`):
  - `$PLUGIN_DATA_ROOT/<name>/PASSWORD` — random 32-char password, mode 0600
  - `$PLUGIN_DATA_ROOT/<name>/ROLE` — the role name
  - `$PLUGIN_DATA_ROOT/<name>/DATABASE` — the database name
  - `$PLUGIN_DATA_ROOT/<name>/LINKS` — newline-delimited list of linked Dokku apps (managed by `link`/`unlink`)
- Tenant DSN format: `postgres://<role>:<password>@<network-host>:5432/<database>`
  - `<network-host>` defaults to `dokku-shared-postgres` (the container name on the shared network).
- Commit cadence: one commit per task's "commit" step. Conventional-Commits style (`feat:`, `test:`, `chore:`, `docs:`).

---

## Task 1: Initialise repo plumbing (GH remote, gitignore, Makefile)

**Files:**
- Create: `.gitignore`
- Create: `Makefile`
- Modify: git remote (add `origin`)

- [ ] **Step 1: Create `.gitignore`**

```gitignore
# bats artefacts
tests/.bats-tmp/
*.log

# editor
.idea/
.vscode/
*.swp
.DS_Store

# local-only test scratch
/tmp-*
```

- [ ] **Step 2: Create `Makefile`**

```makefile
SHELL := /usr/bin/env bash
BATS  ?= bats
SHELLCHECK ?= shellcheck

SH_FILES := commands config functions install \
            $(wildcard subcommands/*) \
            $(wildcard tests/bin/*)

.PHONY: lint test ci

lint:
	$(SHELLCHECK) -x $(SH_FILES)

test:
	$(BATS) tests

ci: lint test
```

- [ ] **Step 3: Add GitHub remote**

The user has not yet created the GitHub repo. Pause here and ask the user to run:

```
gh repo create johannesdwicahyo/dokku-shared-postgres --public --license MIT --description "Dokku plugin: shared multi-tenant Postgres on a single host"
```

Then add the remote:

```bash
git remote add origin git@github.com:johannesdwicahyo/dokku-shared-postgres.git
git branch -M main
git push -u origin main
```

If the user prefers to defer the remote, skip this step and continue. Do not block plan execution on it.

- [ ] **Step 4: Commit**

```bash
git add .gitignore Makefile
git commit -m "chore: add .gitignore and Makefile"
```

---

## Task 2: Update `plugin.toml` and verify scaffold pre-conditions

**Files:**
- Modify: `plugin.toml`

- [ ] **Step 1: Read current `plugin.toml`**

Run: `cat plugin.toml`

Note: the existing scaffold commit (`b8246bb`) already wrote a starter file. Confirm fields match what's below and edit only what differs.

- [ ] **Step 2: Set canonical contents**

```toml
[plugin]
name = "shared-postgres"
description = "Dokku plugin: shared multi-tenant Postgres on a single host"
version = "0.1.0-dev"
license = "MIT"

[plugin.config]
```

- [ ] **Step 3: Commit**

```bash
git add plugin.toml
git commit -m "chore: finalise plugin.toml metadata"
```

---

## Task 3: Author `config` (plugin-wide constants)

**Files:**
- Create: `config`

- [ ] **Step 1: Write `config`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Plugin identity
PLUGIN_COMMAND_PREFIX="shared-postgres"
PLUGIN_SERVICE="shared-postgres"

# Shared Postgres container
PLUGIN_IMAGE="postgres"
PLUGIN_IMAGE_VERSION="16-alpine"
PLUGIN_CONTAINER_NAME="dokku-shared-postgres"
PLUGIN_NETWORK_NAME="dokku-shared-postgres"
PLUGIN_DB_PORT="5432"

# Filesystem layout (overrideable for tests)
PLUGIN_DATA_ROOT="${PLUGIN_DATA_ROOT:-/var/lib/dokku/services/shared-postgres}"
PLUGIN_ADMIN_PASSWORD_FILE="${PLUGIN_DATA_ROOT}/.admin_password"

# Defaults (per-tenant)
PLUGIN_DEFAULT_CONNECTION_LIMIT="${PLUGIN_DEFAULT_CONNECTION_LIMIT:-20}"
PLUGIN_DEFAULT_QUOTA_MB="${PLUGIN_DEFAULT_QUOTA_MB:-150}"

# Tenant name validation
PLUGIN_NAME_REGEX='^[a-z][a-z0-9_-]{0,30}$'

export PLUGIN_COMMAND_PREFIX PLUGIN_SERVICE \
       PLUGIN_IMAGE PLUGIN_IMAGE_VERSION \
       PLUGIN_CONTAINER_NAME PLUGIN_NETWORK_NAME PLUGIN_DB_PORT \
       PLUGIN_DATA_ROOT PLUGIN_ADMIN_PASSWORD_FILE \
       PLUGIN_DEFAULT_CONNECTION_LIMIT PLUGIN_DEFAULT_QUOTA_MB \
       PLUGIN_NAME_REGEX
```

- [ ] **Step 2: Verify ShellCheck passes**

Run: `shellcheck -x config`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add config
git commit -m "feat: add plugin-wide config script"
```

---

## Task 4: Build the test stubbing harness

**Files:**
- Create: `tests/test_helper.bash`
- Create: `tests/bin/docker`
- Create: `tests/bin/psql`
- Create: `tests/bin/dokku`

The harness does three things: (1) per-test isolated `PLUGIN_DATA_ROOT` in `BATS_TEST_TMPDIR`, (2) prepends `tests/bin` to PATH so our stubs replace real binaries, (3) provides logging + canned-response loading for stubs.

- [ ] **Step 1: Write `tests/test_helper.bash`**

```bash
#!/usr/bin/env bash
# Sourced by every .bats file via `load test_helper`.

setup_plugin_env() {
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  export REPO_ROOT

  # Sandbox PLUGIN_DATA_ROOT into the per-test tmpdir.
  export PLUGIN_DATA_ROOT="$BATS_TEST_TMPDIR/data"
  mkdir -p "$PLUGIN_DATA_ROOT"

  # Stub bin must come first.
  export PATH="$REPO_ROOT/tests/bin:$PATH"

  # Stub I/O channels.
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  export STUB_RESPONSES_DIR="$BATS_TEST_TMPDIR/stub_responses"
  mkdir -p "$STUB_RESPONSES_DIR"
  : >"$STUB_LOG"

  # Make `psql` admin password lookup succeed by default.
  printf 'admin-pw\n' >"$BATS_TEST_TMPDIR/data/.admin_password"
  chmod 600 "$BATS_TEST_TMPDIR/data/.admin_password"
}

# Helper: queue a canned response for the next call to <stub_name>.
# Usage: stub_response docker '<container_id>'
stub_response() {
  local stub="$1" body="$2"
  printf '%s' "$body" >>"$STUB_RESPONSES_DIR/$stub.queue"
  printf '\n---END---\n' >>"$STUB_RESPONSES_DIR/$stub.queue"
}

# Helper: count how many times <stub_name> was invoked.
stub_call_count() {
  local stub="$1"
  grep -c "^${stub} " "$STUB_LOG" 2>/dev/null || true
}

# Helper: assert the most recent stub log line matches a regex.
assert_stub_called_with() {
  local stub="$1" regex="$2"
  local line
  line="$(grep "^${stub} " "$STUB_LOG" | tail -n1)"
  [[ "$line" =~ $regex ]] || {
    echo "stub $stub last call did not match: $regex"
    echo "actual: $line"
    return 1
  }
}
```

- [ ] **Step 2: Write `tests/bin/docker`**

```bash
#!/usr/bin/env bash
# Stub: logs args to $STUB_LOG, optionally returns a canned response.
set -euo pipefail
printf 'docker %s\n' "$*" >>"${STUB_LOG:-/dev/null}"

queue="${STUB_RESPONSES_DIR:-}/docker.queue"
if [[ -f "$queue" ]]; then
  body="$(awk 'BEGIN{p=1} /^---END---$/{exit} {if(p)print}' "$queue")"
  # consume that response
  tail -n +"$(($(grep -n '^---END---$' "$queue" | head -n1 | cut -d: -f1) + 1))" \
    "$queue" >"$queue.next" 2>/dev/null || : >"$queue.next"
  mv "$queue.next" "$queue"
  printf '%s\n' "$body"
fi
exit 0
```

- [ ] **Step 3: Write `tests/bin/psql` (identical body, different name)**

```bash
#!/usr/bin/env bash
set -euo pipefail
printf 'psql %s\n' "$*" >>"${STUB_LOG:-/dev/null}"

queue="${STUB_RESPONSES_DIR:-}/psql.queue"
if [[ -f "$queue" ]]; then
  body="$(awk 'BEGIN{p=1} /^---END---$/{exit} {if(p)print}' "$queue")"
  tail -n +"$(($(grep -n '^---END---$' "$queue" | head -n1 | cut -d: -f1) + 1))" \
    "$queue" >"$queue.next" 2>/dev/null || : >"$queue.next"
  mv "$queue.next" "$queue"
  printf '%s\n' "$body"
fi
exit 0
```

- [ ] **Step 4: Write `tests/bin/dokku` (same shape)**

```bash
#!/usr/bin/env bash
set -euo pipefail
printf 'dokku %s\n' "$*" >>"${STUB_LOG:-/dev/null}"
exit 0
```

- [ ] **Step 5: Make stubs executable**

Run: `chmod +x tests/bin/docker tests/bin/psql tests/bin/dokku`

- [ ] **Step 6: Smoke test the harness**

Create a throwaway `tests/_harness_smoke.bats`:

```bash
#!/usr/bin/env bats
load test_helper

setup() { setup_plugin_env; }

@test "stub logs invocation" {
  docker run --rm hello-world
  run cat "$STUB_LOG"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "docker run --rm hello-world" ]]
}

@test "stub returns canned response" {
  stub_response docker 'abc123'
  run docker ps -q
  [[ "$status" -eq 0 ]]
  [[ "$output" == "abc123" ]]
}
```

Run: `bats tests/_harness_smoke.bats`
Expected: 2 tests pass.

Then delete the smoke file: `rm tests/_harness_smoke.bats`. (Its purpose is just to validate the harness in this task; subsequent tasks have richer tests that exercise the same code paths.)

- [ ] **Step 7: Commit**

```bash
git add tests/test_helper.bash tests/bin/
git commit -m "test: add bats stubbing harness for docker/psql/dokku"
```

---

## Task 5: Implement `functions` helpers — start with `generate_password` and `service_exists` (TDD)

**Files:**
- Create: `functions`
- Create: `tests/functions.bats`

- [ ] **Step 1: Write the failing tests**

`tests/functions.bats`:

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/functions.bats`
Expected: all 4 fail with "generate_password: command not found" or "service_exists: command not found".

- [ ] **Step 3: Implement minimal `functions`**

```bash
#!/usr/bin/env bash
# Shared helpers for shared-postgres. Sourced — never executed directly.
set -euo pipefail

generate_password() {
  # 16 random bytes → 32 hex chars. Available everywhere; no openssl dependency.
  od -An -tx1 -N16 /dev/urandom | tr -d ' \n'
}

service_exists() {
  local name="$1"
  [[ -d "$PLUGIN_DATA_ROOT/$name" ]]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/functions.bats`
Expected: 4 of 4 pass.

- [ ] **Step 5: Commit**

```bash
git add functions tests/functions.bats
git commit -m "feat: add generate_password and service_exists helpers"
```

---

## Task 6: Add `validate_name`, `service_dsn`, `service_list` helpers (TDD)

**Files:**
- Modify: `functions`
- Modify: `tests/functions.bats`

- [ ] **Step 1: Add failing tests to `tests/functions.bats`**

Append:

```bash
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
  printf 'foo_role'   >"$PLUGIN_DATA_ROOT/foo/ROLE"
  printf 'secret123'  >"$PLUGIN_DATA_ROOT/foo/PASSWORD"
  printf 'foo'        >"$PLUGIN_DATA_ROOT/foo/DATABASE"
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/functions.bats`
Expected: 7 new failures.

- [ ] **Step 3: Append helpers to `functions`**

```bash
validate_name() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 1
  [[ "$name" =~ $PLUGIN_NAME_REGEX ]] || return 1
}

service_dsn() {
  local name="$1"
  service_exists "$name" || { echo "service does not exist: $name" >&2; return 1; }
  local role pwd db
  role="$(<"$PLUGIN_DATA_ROOT/$name/ROLE")"
  pwd="$(<"$PLUGIN_DATA_ROOT/$name/PASSWORD")"
  db="$(<"$PLUGIN_DATA_ROOT/$name/DATABASE")"
  printf 'postgres://%s:%s@%s:%s/%s\n' \
    "$role" "$pwd" "$PLUGIN_CONTAINER_NAME" "$PLUGIN_DB_PORT" "$db"
}

service_list() {
  [[ -d "$PLUGIN_DATA_ROOT" ]] || return 0
  # List immediate subdirectories only, excluding dotfiles.
  ( cd "$PLUGIN_DATA_ROOT" && \
    find . -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | sort )
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/functions.bats`
Expected: all 11 pass.

- [ ] **Step 5: Commit**

```bash
git add functions tests/functions.bats
git commit -m "feat: add validate_name, service_dsn, service_list helpers"
```

---

## Task 7: Add `run_psql_admin` and `ensure_shared_container` helpers (TDD)

These are the docker/psql-touching helpers — they invoke our stubs in tests, real binaries in production.

**Files:**
- Modify: `functions`
- Modify: `tests/functions.bats`

- [ ] **Step 1: Add failing tests**

Append to `tests/functions.bats`:

```bash
@test "run_psql_admin invokes psql with admin password env and -d postgres" {
  run_psql_admin "SELECT 1"
  run cat "$STUB_LOG"
  [[ "$output" == *"psql"* ]]
  # Asserts -d postgres present and the SQL forwarded via -c.
  assert_stub_called_with psql ".*-d postgres.*"
  assert_stub_called_with psql ".*-c SELECT 1.*"
}

@test "ensure_shared_container is a no-op when container is running" {
  stub_response docker 'dokku-shared-postgres'  # docker ps response
  run ensure_shared_container
  [[ "$status" -eq 0 ]]
  # Should NOT have invoked `docker run`.
  run grep -c '^docker run ' "$STUB_LOG"
  [[ "$output" == "0" ]]
}

@test "ensure_shared_container starts container when missing" {
  stub_response docker ''   # docker ps -> empty
  stub_response docker ''   # docker network create -> empty
  stub_response docker ''   # docker run -> empty
  run ensure_shared_container
  [[ "$status" -eq 0 ]]
  run grep -c '^docker run ' "$STUB_LOG"
  [[ "$output" -ge "1" ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/functions.bats`
Expected: 3 new failures.

- [ ] **Step 3: Append helpers to `functions`**

```bash
# Run a SQL string against the shared container as the admin (postgres) user.
# Reads the admin password from $PLUGIN_ADMIN_PASSWORD_FILE.
run_psql_admin() {
  local sql="$1"
  local pw
  pw="$(<"$PLUGIN_ADMIN_PASSWORD_FILE")"
  PGPASSWORD="$pw" psql \
    -h "$PLUGIN_CONTAINER_NAME" \
    -p "$PLUGIN_DB_PORT" \
    -U postgres \
    -d postgres \
    -v ON_ERROR_STOP=1 \
    -c "$sql"
}

# Make sure the shared Postgres container is up. Idempotent.
ensure_shared_container() {
  # Already running?
  local existing
  existing="$(docker ps --filter "name=^${PLUGIN_CONTAINER_NAME}$" --format '{{.Names}}' || true)"
  if [[ -n "$existing" ]]; then
    return 0
  fi

  # Network (idempotent: ignore "already exists").
  docker network create "$PLUGIN_NETWORK_NAME" >/dev/null 2>&1 || true

  # Admin password (generate on first install).
  if [[ ! -s "$PLUGIN_ADMIN_PASSWORD_FILE" ]]; then
    mkdir -p "$(dirname "$PLUGIN_ADMIN_PASSWORD_FILE")"
    generate_password >"$PLUGIN_ADMIN_PASSWORD_FILE"
    chmod 600 "$PLUGIN_ADMIN_PASSWORD_FILE"
  fi

  local admin_pw
  admin_pw="$(<"$PLUGIN_ADMIN_PASSWORD_FILE")"

  docker run --detach \
    --name "$PLUGIN_CONTAINER_NAME" \
    --network "$PLUGIN_NETWORK_NAME" \
    --restart always \
    -v "${PLUGIN_DATA_ROOT}/_pgdata:/var/lib/postgresql/data" \
    -e "POSTGRES_PASSWORD=${admin_pw}" \
    "${PLUGIN_IMAGE}:${PLUGIN_IMAGE_VERSION}" >/dev/null
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/functions.bats`
Expected: all tests pass (14 total now).

- [ ] **Step 5: ShellCheck**

Run: `shellcheck -x functions config`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add functions tests/functions.bats
git commit -m "feat: add run_psql_admin and ensure_shared_container helpers"
```

---

## Task 8: Implement `service_create` and `service_destroy` (TDD)

**Files:**
- Modify: `functions`
- Create: `tests/service_create_destroy.bats`

- [ ] **Step 1: Write failing tests**

`tests/service_create_destroy.bats`:

```bash
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
  mapfile -t psql_calls < <(grep '^psql ' "$STUB_LOG")
  [[ "${psql_calls[0]}" == *"CREATE ROLE"* ]]
  [[ "${psql_calls[0]}" == *"demo_role"* ]]
  [[ "${psql_calls[0]}" == *"CONNECTION LIMIT 20"* ]]
  [[ "${psql_calls[1]}" == *"CREATE DATABASE"* ]]
  [[ "${psql_calls[1]}" == *"OWNER demo_role"* ]]
  [[ "${psql_calls[2]}" == *"REVOKE"* ]]
  [[ "${psql_calls[2]}" == *"PUBLIC"* ]]
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
  mapfile -t psql_calls < <(grep '^psql ' "$STUB_LOG")
  [[ "${psql_calls[0]}" == *"DROP DATABASE"* ]]
  [[ "${psql_calls[0]}" == *"demo"* ]]
  [[ "${psql_calls[1]}" == *"DROP ROLE"* ]]
  [[ "${psql_calls[1]}" == *"demo_role"* ]]
}

@test "service_destroy is idempotent when tenant is missing" {
  run service_destroy "ghost"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"does not exist"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/service_create_destroy.bats`
Expected: 6 failures (functions not defined).

- [ ] **Step 3: Append to `functions`**

```bash
service_create() {
  local name="$1"
  validate_name "$name" || { echo "invalid tenant name: $name" >&2; return 2; }
  if service_exists "$name"; then
    echo "service already exists: $name" >&2
    return 3
  fi
  ensure_shared_container

  local role="${name}_role"
  local pw
  pw="$(generate_password)"

  # Write metadata BEFORE issuing SQL — destroy can clean up if SQL fails.
  mkdir -p "$PLUGIN_DATA_ROOT/$name"
  printf '%s' "$pw"   >"$PLUGIN_DATA_ROOT/$name/PASSWORD"
  printf '%s' "$role" >"$PLUGIN_DATA_ROOT/$name/ROLE"
  printf '%s' "$name" >"$PLUGIN_DATA_ROOT/$name/DATABASE"
  : >"$PLUGIN_DATA_ROOT/$name/LINKS"
  chmod 600 "$PLUGIN_DATA_ROOT/$name/PASSWORD"

  run_psql_admin "CREATE ROLE \"$role\" LOGIN PASSWORD '$pw' CONNECTION LIMIT $PLUGIN_DEFAULT_CONNECTION_LIMIT;"
  run_psql_admin "CREATE DATABASE \"$name\" OWNER \"$role\";"
  run_psql_admin "REVOKE CONNECT ON DATABASE \"$name\" FROM PUBLIC; GRANT CONNECT ON DATABASE \"$name\" TO \"$role\";"
}

service_destroy() {
  local name="$1"
  validate_name "$name" || { echo "invalid tenant name: $name" >&2; return 2; }
  if ! service_exists "$name"; then
    echo "service does not exist: $name" >&2
    return 3
  fi

  local role
  role="$(<"$PLUGIN_DATA_ROOT/$name/ROLE")"

  # Drop in dependency order: DB first (it depends on role), then role.
  # DROP DATABASE cannot run inside a transaction; psql is fine.
  run_psql_admin "DROP DATABASE IF EXISTS \"$name\";"
  run_psql_admin "DROP ROLE IF EXISTS \"$role\";"

  rm -rf "${PLUGIN_DATA_ROOT:?}/$name"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/service_create_destroy.bats`
Expected: all 6 pass.

- [ ] **Step 5: Run all tests + ShellCheck**

Run: `make ci`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add functions tests/service_create_destroy.bats
git commit -m "feat: implement service_create and service_destroy"
```

---

## Task 9: Implement `service_link` (TDD)

`link` writes `DATABASE_URL` on a Dokku app via `dokku config:set` and records the link in `LINKS`.

**Files:**
- Modify: `functions`
- Create: `tests/service_link.bats`

- [ ] **Step 1: Write failing tests**

`tests/service_link.bats`:

```bash
#!/usr/bin/env bats
load test_helper

setup() {
  setup_plugin_env
  source "$REPO_ROOT/config"
  source "$REPO_ROOT/functions"

  # Pre-create a tenant the unsanitary way (avoids docker stub interaction).
  mkdir -p "$PLUGIN_DATA_ROOT/demo"
  printf 'demo_role' >"$PLUGIN_DATA_ROOT/demo/ROLE"
  printf 'pw'        >"$PLUGIN_DATA_ROOT/demo/PASSWORD"
  printf 'demo'      >"$PLUGIN_DATA_ROOT/demo/DATABASE"
  : >"$PLUGIN_DATA_ROOT/demo/LINKS"
}

@test "service_link sets DATABASE_URL on the app" {
  service_link "demo" "myapp"
  assert_stub_called_with dokku "config:set --no-restart myapp DATABASE_URL=postgres://demo_role:pw@dokku-shared-postgres:5432/demo"
}

@test "service_link records the app in LINKS" {
  service_link "demo" "myapp"
  run cat "$PLUGIN_DATA_ROOT/demo/LINKS"
  [[ "$output" == "myapp" ]]
}

@test "service_link is idempotent (no duplicate LINKS entries)" {
  service_link "demo" "myapp"
  service_link "demo" "myapp"
  run grep -c '^myapp$' "$PLUGIN_DATA_ROOT/demo/LINKS"
  [[ "$output" == "1" ]]
}

@test "service_link errors when tenant is missing" {
  run service_link "ghost" "myapp"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"does not exist"* ]]
}

@test "service_link errors when app is empty" {
  run service_link "demo" ""
  [[ "$status" -ne 0 ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/service_link.bats`
Expected: 5 failures.

- [ ] **Step 3: Append to `functions`**

```bash
service_link() {
  local name="$1" app="${2:-}"
  if ! service_exists "$name"; then
    echo "service does not exist: $name" >&2
    return 3
  fi
  if [[ -z "$app" ]]; then
    echo "app name required" >&2
    return 2
  fi

  local dsn
  dsn="$(service_dsn "$name")"

  dokku config:set --no-restart "$app" "DATABASE_URL=$dsn"

  # Record the link, idempotently.
  local links_file="$PLUGIN_DATA_ROOT/$name/LINKS"
  if ! grep -qx "$app" "$links_file" 2>/dev/null; then
    printf '%s\n' "$app" >>"$links_file"
  fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/service_link.bats`
Expected: all 5 pass.

- [ ] **Step 5: Commit**

```bash
git add functions tests/service_link.bats
git commit -m "feat: implement service_link"
```

---

## Task 10: Author the `commands` dispatcher

**Files:**
- Create: `commands`

- [ ] **Step 1: Write `commands`**

```bash
#!/usr/bin/env bash
set -euo pipefail
[[ "${DOKKU_TRACE:-}" == "1" ]] && set -x

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config
source "$PLUGIN_ROOT/config"

cmd="${1:-}"

# Reject calls that aren't ours so dokku can fall through to other plugins.
case "$cmd" in
  "$PLUGIN_COMMAND_PREFIX"|"$PLUGIN_COMMAND_PREFIX":*) : ;;
  help|"$PLUGIN_COMMAND_PREFIX":help)
    cat <<EOF
Usage: dokku $PLUGIN_COMMAND_PREFIX:<command> [args]

Commands:
  $PLUGIN_COMMAND_PREFIX:create <name>           Create a new tenant database.
  $PLUGIN_COMMAND_PREFIX:destroy <name>          Drop a tenant database and role.
  $PLUGIN_COMMAND_PREFIX:link <name> <app>       Set DATABASE_URL on <app>.
  $PLUGIN_COMMAND_PREFIX:list                    List all tenants on this host.
EOF
    exit 0
    ;;
  *) exit "${DOKKU_NOT_IMPLEMENTED_EXIT:-10}" ;;
esac

# Strip the prefix to find the subcommand name.
sub="${cmd#"$PLUGIN_COMMAND_PREFIX":}"
[[ "$sub" == "$PLUGIN_COMMAND_PREFIX" ]] && sub="default"

sub_script="$PLUGIN_ROOT/subcommands/$sub"
if [[ ! -x "$sub_script" ]]; then
  echo "shared-postgres: unknown subcommand: $sub" >&2
  exit "${DOKKU_NOT_IMPLEMENTED_EXIT:-10}"
fi

shift
exec "$sub_script" "$@"
```

- [ ] **Step 2: Make executable + ShellCheck**

Run: `chmod +x commands && shellcheck -x commands`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add commands
git commit -m "feat: add commands dispatcher"
```

---

## Task 11: Implement `subcommands/create`

**Files:**
- Create: `subcommands/create`
- Create: `tests/cmd_create.bats`

- [ ] **Step 1: Write failing tests**

`tests/cmd_create.bats`:

```bash
#!/usr/bin/env bats
load test_helper

setup() {
  setup_plugin_env
  stub_response docker 'dokku-shared-postgres'  # ensure_shared_container short-circuit
}

@test "subcommands/create creates a tenant and prints the DSN" {
  run "$REPO_ROOT/subcommands/create" "shared-postgres:create" "demo"
  [[ "$status" -eq 0 ]]
  [[ -d "$PLUGIN_DATA_ROOT/demo" ]]
  [[ "$output" == *"postgres://demo_role:"* ]]
  [[ "$output" == *"@dokku-shared-postgres:5432/demo"* ]]
}

@test "subcommands/create exits non-zero on missing arg" {
  run "$REPO_ROOT/subcommands/create" "shared-postgres:create"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"name required"* ]]
}

@test "subcommands/create exits non-zero on invalid name" {
  run "$REPO_ROOT/subcommands/create" "shared-postgres:create" "BAD"
  [[ "$status" -ne 0 ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/cmd_create.bats`
Expected: 3 failures (subcommand doesn't exist yet).

- [ ] **Step 3: Write `subcommands/create`**

```bash
#!/usr/bin/env bash
set -euo pipefail
[[ "${DOKKU_TRACE:-}" == "1" ]] && set -x

PLUGIN_ROOT="$(cd "$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")" && pwd)"
# shellcheck source=../config
source "$PLUGIN_ROOT/config"
# shellcheck source=../functions
source "$PLUGIN_ROOT/functions"

# $1 is the full command (e.g. "shared-postgres:create"); $2 is the tenant name.
shift  # drop command word
name="${1:-}"
if [[ -z "$name" ]]; then
  echo "tenant name required: dokku $PLUGIN_COMMAND_PREFIX:create <name>" >&2
  exit 2
fi

service_create "$name"
service_dsn "$name"
```

- [ ] **Step 4: Make executable**

Run: `chmod +x subcommands/create`

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/cmd_create.bats`
Expected: 3 pass.

- [ ] **Step 6: Commit**

```bash
git add subcommands/create tests/cmd_create.bats
git commit -m "feat: add shared-postgres:create subcommand"
```

---

## Task 12: Implement `subcommands/destroy`

**Files:**
- Create: `subcommands/destroy`
- Create: `tests/cmd_destroy.bats`

- [ ] **Step 1: Write failing tests**

`tests/cmd_destroy.bats`:

```bash
#!/usr/bin/env bats
load test_helper

setup() {
  setup_plugin_env
  source "$REPO_ROOT/config"
  source "$REPO_ROOT/functions"
  # Pre-create a tenant via the helper, with docker short-circuited.
  stub_response docker 'dokku-shared-postgres'
  service_create "demo"
  : >"$STUB_LOG"
}

@test "subcommands/destroy with -f removes the tenant non-interactively" {
  run "$REPO_ROOT/subcommands/destroy" "shared-postgres:destroy" "demo" "-f"
  [[ "$status" -eq 0 ]]
  [[ ! -d "$PLUGIN_DATA_ROOT/demo" ]]
}

@test "subcommands/destroy refuses without -f" {
  run "$REPO_ROOT/subcommands/destroy" "shared-postgres:destroy" "demo"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"-f"* ]]
  [[ -d "$PLUGIN_DATA_ROOT/demo" ]]   # untouched
}

@test "subcommands/destroy errors on missing tenant" {
  run "$REPO_ROOT/subcommands/destroy" "shared-postgres:destroy" "ghost" "-f"
  [[ "$status" -ne 0 ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/cmd_destroy.bats`
Expected: 3 failures.

- [ ] **Step 3: Write `subcommands/destroy`**

```bash
#!/usr/bin/env bash
set -euo pipefail
[[ "${DOKKU_TRACE:-}" == "1" ]] && set -x

PLUGIN_ROOT="$(cd "$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")" && pwd)"
# shellcheck source=../config
source "$PLUGIN_ROOT/config"
# shellcheck source=../functions
source "$PLUGIN_ROOT/functions"

shift  # drop command word
name="${1:-}"
flag="${2:-}"
if [[ -z "$name" ]]; then
  echo "tenant name required: dokku $PLUGIN_COMMAND_PREFIX:destroy <name> -f" >&2
  exit 2
fi
if [[ "$flag" != "-f" && "$flag" != "--force" ]]; then
  echo "refusing to destroy '$name' without -f flag" >&2
  exit 2
fi

service_destroy "$name"
echo "destroyed: $name"
```

- [ ] **Step 4: Make executable + run tests**

Run: `chmod +x subcommands/destroy && bats tests/cmd_destroy.bats`
Expected: 3 pass.

- [ ] **Step 5: Commit**

```bash
git add subcommands/destroy tests/cmd_destroy.bats
git commit -m "feat: add shared-postgres:destroy subcommand"
```

---

## Task 13: Implement `subcommands/link` and `subcommands/list`

**Files:**
- Create: `subcommands/link`
- Create: `subcommands/list`
- Create: `tests/cmd_link.bats`
- Create: `tests/cmd_list.bats`

- [ ] **Step 1: Write failing `link` tests**

`tests/cmd_link.bats`:

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

@test "subcommands/link calls dokku config:set" {
  run "$REPO_ROOT/subcommands/link" "shared-postgres:link" "demo" "myapp"
  [[ "$status" -eq 0 ]]
  run grep '^dokku ' "$STUB_LOG"
  [[ "$output" == *"config:set"* ]]
  [[ "$output" == *"DATABASE_URL=postgres://demo_role:pw@dokku-shared-postgres:5432/demo"* ]]
}

@test "subcommands/link errors on missing args" {
  run "$REPO_ROOT/subcommands/link" "shared-postgres:link" "demo"
  [[ "$status" -ne 0 ]]
}
```

- [ ] **Step 2: Write failing `list` tests**

`tests/cmd_list.bats`:

```bash
#!/usr/bin/env bats
load test_helper

setup() {
  setup_plugin_env
  mkdir -p "$PLUGIN_DATA_ROOT/alpha" "$PLUGIN_DATA_ROOT/beta"
}

@test "subcommands/list prints tenants alphabetically" {
  run "$REPO_ROOT/subcommands/list" "shared-postgres:list"
  [[ "$status" -eq 0 ]]
  expected=$'alpha\nbeta'
  [[ "$output" == "$expected" ]]
}

@test "subcommands/list prints nothing when empty" {
  rm -rf "$PLUGIN_DATA_ROOT"/*
  run "$REPO_ROOT/subcommands/list" "shared-postgres:list"
  [[ "$status" -eq 0 ]]
  [[ -z "$output" ]]
}
```

- [ ] **Step 3: Run both test files to verify failure**

Run: `bats tests/cmd_link.bats tests/cmd_list.bats`
Expected: 4 failures.

- [ ] **Step 4: Write `subcommands/link`**

```bash
#!/usr/bin/env bash
set -euo pipefail
[[ "${DOKKU_TRACE:-}" == "1" ]] && set -x

PLUGIN_ROOT="$(cd "$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")" && pwd)"
# shellcheck source=../config
source "$PLUGIN_ROOT/config"
# shellcheck source=../functions
source "$PLUGIN_ROOT/functions"

shift  # drop command word
name="${1:-}"
app="${2:-}"
if [[ -z "$name" || -z "$app" ]]; then
  echo "usage: dokku $PLUGIN_COMMAND_PREFIX:link <name> <app>" >&2
  exit 2
fi

service_link "$name" "$app"
echo "linked: $name -> $app"
```

- [ ] **Step 5: Write `subcommands/list`**

```bash
#!/usr/bin/env bash
set -euo pipefail
[[ "${DOKKU_TRACE:-}" == "1" ]] && set -x

PLUGIN_ROOT="$(cd "$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")" && pwd)"
# shellcheck source=../config
source "$PLUGIN_ROOT/config"
# shellcheck source=../functions
source "$PLUGIN_ROOT/functions"

service_list
```

- [ ] **Step 6: Make executable + run tests**

Run: `chmod +x subcommands/link subcommands/list && bats tests/cmd_link.bats tests/cmd_list.bats`
Expected: 4 pass.

- [ ] **Step 7: Run full suite + lint**

Run: `make ci`
Expected: full suite green.

- [ ] **Step 8: Commit**

```bash
git add subcommands/link subcommands/list tests/cmd_link.bats tests/cmd_list.bats
git commit -m "feat: add shared-postgres:link and :list subcommands"
```

---

## Task 14: Author `install` (idempotent first-time setup)

`install` is what `dokku plugin:install` ends up running. We won't run it live this session, but we want it correct + ShellCheck-clean.

**Files:**
- Create: `install`

- [ ] **Step 1: Write `install`**

```bash
#!/usr/bin/env bash
set -euo pipefail
[[ "${DOKKU_TRACE:-}" == "1" ]] && set -x

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config
source "$PLUGIN_ROOT/config"
# shellcheck source=functions
source "$PLUGIN_ROOT/functions"

mkdir -p "$PLUGIN_DATA_ROOT"
chmod 0750 "$PLUGIN_DATA_ROOT"

# Pull the image. This is the only operation that genuinely requires
# network access on install — everything else is local.
docker image pull "${PLUGIN_IMAGE}:${PLUGIN_IMAGE_VERSION}"

# Bring up the shared container.
ensure_shared_container

echo "shared-postgres: install complete"
```

- [ ] **Step 2: Make executable + ShellCheck**

Run: `chmod +x install && shellcheck -x install`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add install
git commit -m "feat: add install hook (image pull + container bootstrap)"
```

---

## Task 15: GitHub Actions CI

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  lint:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - name: Install ShellCheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck
      - run: make lint

  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - name: Install bats
        run: sudo apt-get update && sudo apt-get install -y bats
      - run: make test
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add ShellCheck + bats workflow"
```

- [ ] **Step 3: (After remote is set) push and verify green**

Run: `git push origin main`
Then check the Actions tab on GitHub. Expected: both jobs green.

If the remote is not yet set (Task 1 Step 3 was skipped), defer this verification to the session that wires the remote up.

---

## Task 16: README pass — install + four-command usage

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read current README**

Run: `cat README.md`

- [ ] **Step 2: Update with the canonical install + usage section**

Replace the body with (preserve any existing top-of-file badges if present):

```markdown
# dokku-shared-postgres

Shared, multi-tenant Postgres on a single Dokku host. One Postgres container
per host, per-tenant Postgres role + database, password isolation.

> **Status:** v0.1.0-dev. CLI surface: `create`, `destroy`, `link`, `list`.
> `info`, `connect`, `export`, `import`, `set-quota` are landing in v0.1.

## Install

```sh
dokku plugin:install https://github.com/johannesdwicahyo/dokku-shared-postgres.git shared-postgres
```

## Usage

```sh
# Provision a tenant database:
dokku shared-postgres:create myapp_db
# -> postgres://myapp_db_role:<random>@dokku-shared-postgres:5432/myapp_db

# Link it to a Dokku app (sets DATABASE_URL on the app):
dokku shared-postgres:link myapp_db myapp

# List all tenants on this host:
dokku shared-postgres:list

# Drop a tenant (use -f because there is no recovery):
dokku shared-postgres:destroy myapp_db -f
```

## Architecture

- One shared `postgres:16-alpine` container per host, on the
  `dokku-shared-postgres` Docker network.
- Each tenant gets a Postgres ROLE (`<name>_role`) and a DATABASE (`<name>`).
  `CONNECT` on the database is revoked from `PUBLIC` and granted only to
  the role. Default per-role connection limit: 20.
- Per-tenant metadata (password, role, database, linked apps) lives in
  `/var/lib/dokku/services/shared-postgres/<name>/`.

## License

MIT — see [LICENSE](./LICENSE).
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: install + usage docs for v0.1.0-dev surface"
```

---

## Task 17: Final verification

- [ ] **Step 1: Full CI locally**

Run: `make ci`
Expected: ShellCheck clean, all bats tests pass.

- [ ] **Step 2: Inventory expected file set**

Run:

```bash
git ls-files | sort
```

Expected entries (at minimum):

```
.github/workflows/ci.yml
.gitignore
CLAUDE.md
LICENSE
Makefile
README.md
commands
config
docs/superpowers/plans/2026-05-07-scaffold-create-destroy-link.md
functions
install
plugin.toml
subcommands/create
subcommands/destroy
subcommands/link
subcommands/list
tests/bin/docker
tests/bin/dokku
tests/bin/psql
tests/cmd_create.bats
tests/cmd_destroy.bats
tests/cmd_link.bats
tests/cmd_list.bats
tests/functions.bats
tests/service_create_destroy.bats
tests/service_link.bats
tests/test_helper.bash
```

- [ ] **Step 3: Confirm executable bits**

Run:

```bash
ls -l commands install subcommands/* tests/bin/*
```

Expected: every listed file has `x` for owner.

- [ ] **Step 4: Push (if remote is configured)**

Run: `git push origin main`

If no remote: stop here and report success.

---

## Self-review notes (recorded by the planner)

- **Spec coverage:** CLAUDE.md "first session's job" = scaffolding + create + destroy + link → covered by Tasks 3–13. `list` was added because `link` tests need it and it costs almost nothing. `info`, `connect`, quota, export/import, the periodic trigger, `pre-install` → explicitly out of scope; deferred.
- **TDD discipline:** every code-bearing task uses red→green ordering. The four `subcommands/*` files all get tests before implementation.
- **No live Dokku host:** verified — the harness stubs `docker`, `psql`, and `dokku`. `install` is authored but never executed in this session; correctness rests on ShellCheck plus the unit-tested helpers it composes.
- **Type/name consistency:** `service_create`/`service_destroy`/`service_link`/`service_dsn`/`service_list`/`service_exists`/`validate_name`/`generate_password`/`run_psql_admin`/`ensure_shared_container` — used identically across tasks.
- **Bash hazards covered:** `set -euo pipefail` everywhere; `${PLUGIN_DATA_ROOT:?}` guard on the destructive `rm -rf`; password file mode 0600; tenant-name regex anchored.
