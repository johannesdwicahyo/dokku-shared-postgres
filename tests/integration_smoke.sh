#!/usr/bin/env bash
#
# Integration smoke for shared-postgres. Run on a real Dokku host after
# installing the plugin. Not invoked by CI — local bats stubs can't catch
# the failure modes this script exists to verify (perms, peer auth,
# docker-network DNS, Dokku 0.38 dispatch).
#
# Usage:
#   ssh root@my-dokku-host 'bash -s' < tests/integration_smoke.sh
# or run directly on the host as root.
#
# The script is intentionally chatty and fail-fast: every step prints what
# it expects to see; if reality differs, fix the plugin before tagging.

set -euo pipefail

TENANT="${TENANT:-smoke-test-$(date +%s)}"
APP="${APP:-smoke-app-$(date +%s)}"

step() { printf '\n=== %s ===\n' "$1"; }

cleanup() {
  set +e
  step "cleanup"
  ssh -o StrictHostKeyChecking=no dokku@localhost "apps:destroy $APP --force" 2>/dev/null || true
  ssh -o StrictHostKeyChecking=no dokku@localhost "shared-postgres:destroy $TENANT -f" 2>/dev/null || true
}
trap cleanup EXIT

step "1. plugin installed and dispatcher responds"
sudo -u dokku dokku shared-postgres:help | grep -q "create <name>" \
  || { echo "FAIL: :help output missing 'create <name>'"; exit 1; }

step "2. data dir is dokku-owned"
ls -ld /var/lib/dokku/services/shared-postgres | awk '{print "  perm/owner:", $1, $3, $4}'
[[ "$(stat -c '%U:%G' /var/lib/dokku/services/shared-postgres)" == "dokku:dokku" ]] \
  || { echo "FAIL: data dir not owned by dokku:dokku"; exit 1; }

step "3. shared container is up"
docker ps --filter "name=^dokku-shared-postgres$" --format '{{.Names}} {{.Status}}' | grep -q dokku-shared-postgres \
  || { echo "FAIL: shared container not running"; exit 1; }

step "4. create tenant '$TENANT' via the dokku user"
sudo -u dokku dokku shared-postgres:create "$TENANT" | tee /tmp/.smoke-dsn
grep -q "postgres://${TENANT}_role:" /tmp/.smoke-dsn \
  || { echo "FAIL: DSN didn't print"; exit 1; }

step "5. info reports the tenant"
sudo -u dokku dokku shared-postgres:info "$TENANT" | tee /tmp/.smoke-info
grep -q "Name:.*$TENANT"      /tmp/.smoke-info || { echo "FAIL: info missing Name"; exit 1; }
grep -q "Role:.*${TENANT}_role" /tmp/.smoke-info || { echo "FAIL: info missing Role"; exit 1; }
grep -q "Size:"               /tmp/.smoke-info || { echo "FAIL: info missing Size"; exit 1; }

step "6. quota: set, sweep, observe"
sudo -u dokku dokku shared-postgres:set-quota "$TENANT" 1
sudo -u dokku dokku shared-postgres:check-quotas
# Tenant is empty, well under 1 MB cap — no flipped/released line expected.

step "7. link to a Dokku app and verify DATABASE_URL"
sudo -u dokku dokku apps:create "$APP"
sudo -u dokku dokku shared-postgres:link "$TENANT" "$APP"
dsn="$(sudo -u dokku dokku config:get "$APP" DATABASE_URL)"
[[ "$dsn" == "postgres://${TENANT}_role:"* ]] \
  || { echo "FAIL: DATABASE_URL not set on $APP: $dsn"; exit 1; }
echo "  DATABASE_URL=$dsn"

step "8. export round-trips through import"
sudo -u dokku dokku shared-postgres:export "$TENANT" > /tmp/.smoke-dump
[[ -s /tmp/.smoke-dump ]] || { echo "FAIL: export produced no output"; exit 1; }
sudo -u dokku dokku shared-postgres:import "$TENANT" < /tmp/.smoke-dump

step "9. list shows the tenant"
sudo -u dokku dokku shared-postgres:list | grep -q "^$TENANT$" \
  || { echo "FAIL: list didn't include $TENANT"; exit 1; }

step "10. destroy"
sudo -u dokku dokku shared-postgres:destroy "$TENANT" -f
sudo -u dokku dokku shared-postgres:list | grep -q "^$TENANT$" \
  && { echo "FAIL: tenant still in list after destroy"; exit 1; } || true

echo
echo "=== ALL SMOKE STEPS PASSED ==="
