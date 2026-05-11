# Fixes Required for v0.2.0 (Production Readiness)

Found 2026-05-11 during wokku-cloud integration smoke test on jkt-01 (Dokku 0.38.0).

The plugin's CLI works under `bash -x .../commands shared-postgres:create foo` but **fails when invoked the way Dokku 0.38 actually dispatches**. Three real bugs surfaced; all need fixing before the plugin can be advertised or used in production.

---

## Bug 1 — Subcommand arg handling: Dokku passes `cmd:sub` as `$1`, not just the user args

**Symptom:**
```bash
$ ssh dokku@host "shared-postgres:create my-app"
invalid tenant name: shared-postgres:create
```

**Root cause:**
Dokku 0.38 invokes plugin subcommands as `subcommands/<name> <full_cmd> <user_args...>` — so `$1 = "shared-postgres:create"`, user args start at `$2`. The plugin's `commands` router (which DOES shift correctly) is bypassed for subcommand-style invocations in modern Dokku. Every script in `subcommands/` currently assumes `$1` is the user arg.

Confirmed by comparing against `/var/lib/dokku/plugins/available/postgres/subcommands/create` (the official dokku-postgres plugin) — it ends with `service-create-cmd "$@"` and inside the function does `service_create "$SERVICE" "${@:2}"`, meaning $1 is treated as the cmd name and shifted off.

**Fix:**
At the top of EVERY script under `subcommands/` (except `list` and `check-quotas` which take no user args), add a single line **after** the `source` lines and **before** any `${1}` reference:

```bash
shift  # Dokku passes plugin:cmd as $1; drop it so user args start at $1
```

Affected files:
- `subcommands/create`
- `subcommands/destroy`
- `subcommands/info`
- `subcommands/link`
- `subcommands/connect`
- `subcommands/set-quota`
- `subcommands/unset-quota`
- `subcommands/export`
- `subcommands/import`

Unaffected (take no user args):
- `subcommands/list`
- `subcommands/check-quotas`

**Add a regression test** to `tests/` that invokes each subcommand via `commands` AND directly as Dokku would, asserting the same result.

---

## Bug 2 — `install` hook leaves data dir root-owned

**Symptom:**
```bash
$ ssh dokku@host "shared-postgres:create my-app"
mkdir: cannot create directory '/var/lib/dokku/services/shared-postgres': Permission denied
```

**Root cause:**
`install` runs as root and creates `/var/lib/dokku/services/shared-postgres/` (mode 0750, owner root:root). All runtime invocations of plugin subcommands run as the `dokku` user via SSH, which can't write to the root-owned dir.

Compare to official Dokku plugins under the same path — they're all `dokku:dokku` owned.

**Fix:**
In `install` (the plugin's install hook), after creating `$PLUGIN_DATA_ROOT` and the admin password file, add:

```bash
chown -R dokku:dokku "$PLUGIN_DATA_ROOT"
chmod 0750 "$PLUGIN_DATA_ROOT"
```

If `_pgdata` (the postgres data subdir) needs to stay `70:root` (the postgres user inside the container), exclude it:

```bash
chown dokku:dokku "$PLUGIN_DATA_ROOT" "$PLUGIN_ADMIN_PASSWORD_FILE"
# Don't chown _pgdata — postgres container UID 70 owns it
```

Add an idempotency check at the top so re-install doesn't fight existing perms:

```bash
[[ -d "$PLUGIN_DATA_ROOT" ]] && [[ "$(stat -c '%U' "$PLUGIN_DATA_ROOT")" == "dokku" ]] && exit 0
```

---

## Bug 3 — `run_psql_admin` calls host `psql` against a Docker-internal hostname

**Symptom:**
```bash
$ ssh dokku@host "shared-postgres:create my-app"
/var/lib/dokku/plugins/enabled/shared-postgres/functions: line 52: psql: command not found
```

**Root cause:**
`functions:run_psql_admin` invokes the host's `psql` binary with `-h "$PLUGIN_CONTAINER_NAME"` (= `dokku-shared-postgres`). Two problems:

1. **The host probably doesn't have `psql` installed.** Bare Dokku boxes don't ship the postgres-client package. Even if they did, requiring it makes the plugin OS-dependent.

2. **`dokku-shared-postgres` is a Docker container name.** It only resolves inside Docker networks. The dokku user shell on the host is NOT on the plugin's Docker network — `psql -h dokku-shared-postgres` would fail with DNS even with psql installed.

The plugin needs to execute psql **inside** the container via `docker exec`. That's how every official Dokku data-service plugin operates.

**Fix:**
Rewrite `functions:run_psql_admin` (and any sibling helper that does the same thing — search for `psql ` and `PGPASSWORD=`) to use `docker exec`:

```bash
# Run psql as the admin user inside the shared container.
# All callers route through here so the docker-exec invocation
# stays in one place.
run_psql_admin() {
  local sql="$1"
  shift || true
  local pw
  pw="$(<"$PLUGIN_ADMIN_PASSWORD_FILE")"
  docker exec -i \
    -e "PGPASSWORD=$pw" \
    "$PLUGIN_CONTAINER_NAME" \
    psql \
      -U postgres \
      -d postgres \
      -v ON_ERROR_STOP=1 \
      "$@" \
      -c "$sql"
}
```

Audit every other function in `functions` for the same anti-pattern:

```bash
grep -n 'psql\|pg_dump\|pg_restore\|createdb\|dropdb' functions
```

Each occurrence that targets the shared container needs to be wrapped in `docker exec "$PLUGIN_CONTAINER_NAME" <cmd>` rather than calling the binary directly from the host.

The `export` and `import` subcommands need the same treatment for `pg_dump` / `psql` invocations.

---

## Bug 4 (Minor) — `shared-postgres:help` not handled

**Symptom:**
```bash
$ ssh dokku@host "shared-postgres:help"
shared-postgres: unknown subcommand: help
```

The `commands` router's case statement DOES match `help|"$PLUGIN_COMMAND_PREFIX":help` and prints usage. But modern Dokku skips the `commands` router for subcommand-style invocations and looks for `subcommands/help` — which doesn't exist.

**Fix:**
Add `subcommands/help` that prints the same usage block. Same content as the help text already in `commands` — extract to a shared file or duplicate.

---

## Bug 5 (Minor) — README "Status" line should call out 0.1.0-dev limitations

Update `README.md` to note: **v0.1.0-dev is not production-ready due to bugs 1–3 above.** Don't drop the warning until v0.2.0 ships with all five fixed and verified end-to-end on Dokku 0.38+.

---

## Test plan for v0.2.0

After applying fixes 1–4, run the full smoke from a clean Dokku install:

```bash
# On a fresh Dokku host:
dokku plugin:install https://github.com/johannesdwicahyo/dokku-shared-postgres.git shared-postgres

# Verify install perms:
ls -la /var/lib/dokku/services/shared-postgres
# Expected: drwxr-x--- ... dokku dokku ...

# Provision a tenant via the dokku user (as wokku-cloud does):
ssh dokku@host "shared-postgres:create test-tenant-001"
# Expected: prints postgres://test-tenant-001_role:<pw>@dokku-shared-postgres:5432/test-tenant-001_db

# Info:
ssh dokku@host "shared-postgres:info test-tenant-001"
# Expected: Name, Role, Database, Size (MB), Connection Limit, Linked Apps key:value lines

# Quota:
ssh dokku@host "shared-postgres:set-quota test-tenant-001 200"
ssh dokku@host "shared-postgres:check-quotas"
# Expected: one line "test-tenant-001 <N>MB 200MB over=false revoked=false"

# Link to a real Dokku app and verify DATABASE_URL works:
dokku apps:create test-app
ssh dokku@host "shared-postgres:link test-tenant-001 test-app"
dokku config:get test-app DATABASE_URL
# Expected: the postgres:// URL from the create step

# Destroy:
ssh dokku@host "shared-postgres:destroy test-tenant-001 -f"
ssh dokku@host "shared-postgres:list"
# Expected: empty
```

Add this scripted smoke as `tests/integration_smoke.sh` for CI.

---

## After v0.2.0 ships

1. `git tag v0.2.0 && git push --tags` in this repo.
2. Update wokku-cloud's `scripts/provision-dokku-server.sh` to pin the tag:
   ```bash
   sudo -u dokku dokku plugin:install https://github.com/johannesdwicahyo/dokku-shared-postgres.git#v0.2.0 shared-postgres || true
   ```
3. Reinstall on jkt-01:
   ```bash
   ssh root@103.190.0.43 'dokku plugin:install https://github.com/johannesdwicahyo/dokku-shared-postgres.git#v0.2.0 shared-postgres'
   ```
4. Run the wokku-cloud smoke from console (this same Phase 5 plan, Task 7 step 4).
5. Advertise the free tier publicly.
