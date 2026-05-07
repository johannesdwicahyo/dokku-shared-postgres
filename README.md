# dokku-shared-postgres

[![CI](https://github.com/johannesdwicahyo/dokku-shared-postgres/actions/workflows/ci.yml/badge.svg)](https://github.com/johannesdwicahyo/dokku-shared-postgres/actions/workflows/ci.yml)

> **Status: scaffolding.** Project just kicked off. APIs and commands documented below are the **plan**, not the current state.

A [Dokku](https://dokku.com) plugin that provides **shared, multi-tenant Postgres** on a single host. One Postgres container per host; each tenant gets a Postgres role + database with limited privileges, plus quota enforcement.

Designed for hosts running many small apps that don't each need their own Postgres container — saves memory, easier to manage, easier to back up. Powers [wokku.cloud](https://wokku.cloud)'s free Postgres tier.

## Install (planned)

```bash
dokku plugin:install https://github.com/johannesdwicahyo/dokku-shared-postgres.git
```

## Commands (planned)

```bash
dokku shared-postgres:create my-db
dokku shared-postgres:link my-db my-app          # sets DATABASE_URL
dokku shared-postgres:connect my-db              # interactive psql
dokku shared-postgres:info my-db                 # name, owner, size, conns
dokku shared-postgres:list                       # all tenants on host
dokku shared-postgres:set-quota my-db 250        # MB
dokku shared-postgres:export my-db > dump.sql
dokku shared-postgres:import my-db < dump.sql
dokku shared-postgres:destroy my-db
```

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
