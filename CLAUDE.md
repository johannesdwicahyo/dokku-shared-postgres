# CLAUDE.md — dokku-shared-postgres

> This file is the **complete onboarding brief** for a fresh Claude Code session
> picking up this project. Read top-to-bottom before doing anything.

## What this project is

A new OSS Dokku plugin that provides **shared, multi-tenant Postgres** on a
single host. One Postgres container per host, per-tenant Postgres role + DB
with limited privileges, ACL isolation, plugin-level quota enforcement.

Released as a standalone Dokku plugin under MIT (target). The same plugin
backs **wokku.cloud's free Postgres tier** — Wokku is the maintainer +
primary user.

## Why now (raised 2026-05-06)

1. Most new wokku.cloud signups land on the free Postgres tier. First
   impression infra — quality compounds.
2. wokku-cloud's current free-tier setup uses the standard Dokku postgres
   plugin + an in-app `SharedDatabaseQuotaJob`. Moving the multi-tenancy
   and quota logic into a dedicated plugin puts it where it belongs and
   simplifies wokku-cloud.
3. Existing OSS prior art (`github.com/jeffutter/dokku-postgresql-plugin`)
   is unmaintained — opportunity for Wokku to own the canonical
   shared-Postgres-on-Dokku plugin.
4. Aligns with OSS strategy: Wokku monetizes the managed UI, not the
   underlying Dokku platform; shipping more OSS Dokku plugins strengthens
   the brand without cannibalising revenue.

## Architecture (decided)

- **One shared Postgres container per host.** Started by the plugin via
  `dokku plugin:install` follow-up (or first `shared-postgres:create`
  call). Image: official `postgres:16-alpine`. Persistent volume for data.
  Network on `dokku-postgres` Docker network so dokku-linked apps reach it.

- **Per-tenant Postgres role + database.** When a Dokku user runs
  `shared-postgres:create <name>`:
  1. The plugin creates a Postgres ROLE `<name>_role` (random password).
  2. Creates a database `<name>` owned by that role.
  3. Revokes connect on `<name>` from PUBLIC; grants only to `<name>_role`.
  4. Optionally sets per-database quotas via `tablespace` sizing or
     extension-based enforcement (see "Quota" below).
  5. Stores the password + connection metadata in the plugin's data
     directory (`/var/lib/dokku/services/shared-postgres/<name>/`),
     mirroring the standard plugin's layout so consumers know where to
     look.

- **`shared-postgres:link <db> <app>`** sets `DATABASE_URL` on the app
  pointing to `postgres://<name>_role:<pwd>@dokku-shared-postgres:5432/<name>`.

- **`shared-postgres:connect <db>`** SSHes into the container as the
  tenant role and drops into psql.

- **Backup story (v1):** per-tenant `pg_dump` to a host-mounted directory
  on a daily cron. Restoration via `shared-postgres:import`. Snapshot of
  the whole host volume is out of scope for v1 (admin/operator concern).

## Quota enforcement

- **Size cap:** Postgres has no native per-database hard cap. Two options
  evaluated:
  1. `tablespace` per tenant + Linux quota on the tablespace path.
     **Complex; rejected for v1.**
  2. **Periodic `pg_database_size()` check** (every 5 min) — when a tenant
     exceeds the cap, run `ALTER DATABASE <name> SET default_transaction_read_only = on`
     so writes fail cleanly until they free space or the operator
     intervenes. Default cap: 150 MB (matches wokku-cloud's existing
     free-tier ceiling). Operator overrideable per tenant.
  **v1: option 2.**

- **Connection cap:** `ALTER ROLE <name>_role CONNECTION LIMIT 20` at
  creation (default; configurable).

## Compatible CLI surface

Mirror the standard `dokku-postgres` plugin's command list so users can
substitute it transparently. At least:

- `shared-postgres:create <name>`
- `shared-postgres:destroy <name>`
- `shared-postgres:info <name>` — name, owner, size, role, conn count
- `shared-postgres:list` — all tenants on this host
- `shared-postgres:link <name> <app>` — write `DATABASE_URL` env on app
- `shared-postgres:unlink <name> <app>` — remove env
- `shared-postgres:connect <name>` — interactive psql as tenant role
- `shared-postgres:promote <name> <app>` — make this the primary `DATABASE_URL`
- `shared-postgres:export <name>` — `pg_dump` to stdout
- `shared-postgres:import <name>` — restore from stdin
- `shared-postgres:set-quota <name> <mb>` — per-tenant size cap

The plugin name (`shared-postgres` vs `dokku-shared-postgres`) is open;
final decision goes in `plugin.toml`.

## Dokku plugin format reference

Dokku plugins are **Bash scripts** following a strict directory layout:

```
shared-postgres/
├── plugin.toml             # name, version, description
├── README.md
├── LICENSE                 # MIT
├── commands                # main subcommand dispatcher (executable)
├── subcommands/
│   ├── create
│   ├── destroy
│   ├── info
│   ├── list
│   └── ...
├── functions               # shared bash helpers (sourced)
├── pre-install             # runs on `dokku plugin:install`
├── post-install            # runs after install
├── triggers/               # hooks into Dokku lifecycle (post-deploy, etc.)
└── tests/                  # bats / shellspec
```

Reference: https://dokku.com/docs/development/plugin-creation/

## Prior art to study (do this first)

- `github.com/jeffutter/dokku-postgresql-plugin` — the unmaintained
  plugin we're rebuilding. Read it. Note what it does and what it
  doesn't.
- `github.com/dokku/dokku-postgres` — the standard (per-tenant
  container) plugin. Mirror its CLI surface and the bash idioms it uses.
- `github.com/dokku/dokku-redis` — same family.

## Wokku-cloud integration points (consumer side)

Once the plugin ships and is installed on wokku-cloud's hosts:

- `app/services/billing/shared_database_quota_job.rb` (in wokku-cloud)
  becomes a thin caller of `shared-postgres:set-quota` rather than
  computing quota state in Ruby.
- `app/models/database_service.rb` `service_type == "postgres"` records
  with `tier_name == "free"` route through the shared plugin instead of
  the standard one.
- The 150 MB / 100 MB cap (memory note `project_shared_postgres.md` in
  wokku-cloud) is the default `--quota` value for tenants created from
  the wokku-cloud UI.
- `Dokku::Client` in wokku-cloud just runs `dokku shared-postgres:create`
  / `:link` / etc. — no new abstraction needed.

## Workflow rules

- **License:** MIT (file in repo root).
- **Code style:** ShellCheck-clean Bash, indented with 2 spaces. Use
  `set -euo pipefail` at the top of every script. Match the bash
  conventions in dokku-postgres for consistency.
- **Tests:** `bats-core` for command tests + ShellCheck in CI. Every
  subcommand has at least one bats test.
- **CI:** GitHub Actions matrix on Ubuntu 22.04 + Ubuntu 24.04, with
  Dokku 0.36.x and 0.37.x. Confirm 0.38 compatibility but don't gate
  release on it.
- **Versioning:** semver. v0.x while the API may break. v1.0 once the
  surface is stable.
- **Releases:** GitHub release with a generated `.tar.gz` so users can
  install via `dokku plugin:install <release-url>`.
- **Branch flow:** `main` is always installable. Features in
  `feat/<name>` branches, PR to main when ready. NO direct commits to
  main.

## Success criteria for v0.1.0

- Plugin installs cleanly on a fresh Dokku 0.37 host.
- Can create + destroy a tenant, link to an app, write to the linked DB
  from the app, read it back.
- Quota check actually flips read-only when a tenant exceeds its cap.
- Backup + restore round-trip preserves data.
- README has clear install + usage docs.
- Basic CI green (ShellCheck + bats).

## Out of scope for v0.1.0

- HA / replication. Single host is fine; multi-host is v0.2+.
- Web UI. CLI is the entire interface.
- Migration from standard dokku-postgres. v0.2 problem.
- Metrics / monitoring integration. Document hooks for operators to
  wire their own.

## How to start

1. Read this file end to end. Then read the prior-art repos noted above.
2. `git remote add origin git@github.com:johannesdwicahyo/dokku-shared-postgres.git`
   (create the GitHub repo first; public, MIT, no README).
3. Scaffold the directory structure listed in "Dokku plugin format
   reference" above. Stub each subcommand with `set -euo pipefail` +
   "TODO" + a help line.
4. Wire `commands` to dispatch subcommands via `case` on `$1`.
5. Write `pre-install` to verify Docker is available and pull the
   `postgres:16-alpine` image.
6. Implement `create` and `destroy` first — these are the foundation.
   Get them passing a basic bats test before moving on.
7. Then `link`, `info`, `list`, `connect`.
8. Then quota enforcement (the trigger that runs every 5 min via
   Dokku's `cron-resync` or a plugin-installed cron).
9. Then `export` / `import` for backup.
10. Tag v0.1.0 once the success criteria above are met.

## Work to defer to a follow-up session

The first session's job is **scaffolding + create + destroy + link**.
Everything else is cleanly separable into follow-up sessions.

## Pasted memory notes for context

### From wokku-cloud's `project_shared_postgres.md` (2026-04-24)

> Shared free Postgres architecture, shipped 2026-04-24: shared host
> container + per-tenant role+DB, SharedDatabaseQuotaJob enforces 150 MB
> with 24h grace.

### From wokku-cloud's `feedback_no_cap_on_shared_free.md`

> Unlike free dyno, users can have unlimited shared PG tenants.

### Decision (2026-05-06)

Tier 1 promotion (was Tier 5). Most new users land on free tiers; the
foundation's quality compounds. Sequenced before the redis sibling
plugin since Postgres is harder and we want the architecture right
before duplicating it.
