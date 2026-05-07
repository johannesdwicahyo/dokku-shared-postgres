# dokku-shared-postgres

[![CI](https://github.com/johannesdwicahyo/dokku-shared-postgres/actions/workflows/ci.yml/badge.svg)](https://github.com/johannesdwicahyo/dokku-shared-postgres/actions/workflows/ci.yml)

> **Status: v0.1.0-dev.** Full CLI surface: `create`, `destroy`, `link`, `list`, `info`, `connect`, `set-quota`, `unset-quota`, `check-quotas`, `export`, `import`.

A [Dokku](https://dokku.com) plugin that provides **shared, multi-tenant Postgres** on a single host. One Postgres container per host; each tenant gets a Postgres role + database with limited privileges, plus quota enforcement.

Designed for hosts running many small apps that don't each need their own Postgres container — saves memory, easier to manage, easier to back up. Powers [wokku.cloud](https://wokku.cloud)'s free Postgres tier.

## Install

```bash
dokku plugin:install https://github.com/johannesdwicahyo/dokku-shared-postgres.git shared-postgres
```

## Usage

```bash
# Provision a tenant database:
dokku shared-postgres:create myapp_db
# -> postgres://myapp_db_role:<random>@dokku-shared-postgres:5432/myapp_db

# Link it to a Dokku app (sets DATABASE_URL on the app):
dokku shared-postgres:link myapp_db myapp

# List all tenants on this host:
dokku shared-postgres:list

# Inspect a tenant (size, active connections, linked apps):
dokku shared-postgres:info myapp_db

# Open an interactive psql session as the tenant role:
dokku shared-postgres:connect myapp_db

# Back up a tenant:
dokku shared-postgres:export myapp_db > backup.sql

# Restore from a backup (tenant must exist):
dokku shared-postgres:import myapp_db < backup.sql

# Drop a tenant (use -f because there is no recovery):
dokku shared-postgres:destroy myapp_db -f
```

## Architecture

- One shared `postgres:16-alpine` container per host, on the `dokku-shared-postgres` Docker network.
- Each tenant gets a Postgres ROLE (`<name>_role`) and a DATABASE (`<name>`). `CONNECT` on the database is revoked from `PUBLIC` and granted only to the role. Default per-role connection limit: 20.
- Per-tenant metadata (password, role, database, linked apps) lives in `/var/lib/dokku/services/shared-postgres/<name>/`.

## Quotas

Each tenant has a soft size cap (default 150 MB). A cron job runs every 5 minutes and flips the database to `default_transaction_read_only = on` when the cap is exceeded; the same job releases the read-only flag once the tenant frees enough space.

```bash
# Raise the cap for a chatty tenant:
dokku shared-postgres:set-quota myapp_db 500

# Clear the override (back to the global default):
dokku shared-postgres:unset-quota myapp_db

# Run the sweep on demand:
dokku shared-postgres:check-quotas
```

The cron entry lives at `/etc/cron.d/dokku-shared-postgres`. Remove that file to disable automatic enforcement; you can still call `check-quotas` by hand.

## Why "shared"?

The standard `dokku-postgres` plugin spawns one container per database. Great for production isolation, expensive for small/hobby apps. This plugin runs **one container, many tenants** with Postgres-level isolation (roles + ACL). Trade-off: tenants share resources; not for high-load production.

## Comparison

|   | Standard `dokku-postgres` | `dokku-shared-postgres` |
|---|---|---|
| Container count | One per database | One per host |
| Memory | ~250 MB × N tenants | ~250 MB total |
| Isolation | Container-level | Postgres role + ACL |
| Best for | Production, isolation-critical | Hobby apps, free tiers, multi-tenant SaaS |

## Prior art

This project rebuilds the unmaintained [jeffutter/dokku-postgresql-plugin](https://github.com/jeffutter/dokku-postgresql-plugin) with a maintained, tested, well-documented OSS plugin.

## License

MIT — see `LICENSE`.
