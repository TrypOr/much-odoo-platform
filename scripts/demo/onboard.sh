#!/usr/bin/env bash
# Demo: onboard a new customer end to end and time it.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

name="${1:?usage: onboard.sh <tenant> [size]}"; size="${2:-s}"
[[ "$name" =~ ^[a-z][a-z0-9-]{1,20}$ ]] || { echo "tenant name must be lowercase dns-safe"; exit 1; }

if grep -qE "^$name:" tenants.yaml; then
  log "$name already in tenants.yaml"
else
  log "Adding $name (size $size) to tenants.yaml"
  printf '%s:\n  size: %s\n' "$name" "$size" >> tenants.yaml
fi

start=$(date +%s)
log "terraform apply (only $name's resources change)"
tf apply -auto-approve -input=false | grep -E "Plan:|Apply complete"
log "Waiting for Odoo"
kubectl -n "$name" rollout status deploy/odoo --timeout=900s
log "$name is live at https://$name.localtest.me:8443 after $(( $(date +%s) - start ))s"

log "First filestore backup now, not in 15 minutes"
kubectl -n "$name" create job "filestore-backup-initial" --from=cronjob/filestore-backup >/dev/null
kubectl -n "$name" wait job/filestore-backup-initial --for=condition=complete --timeout=300s >/dev/null

log "Waiting for the external probe to see $name"
for _ in $(seq 1 30); do [ "$(prom "probe_success{job=\"odoo-login\",tenant=\"$name\"}")" = 1 ] && break; sleep 5; done
log "$name fully onboarded (live, backed up, monitored) after $(( $(date +%s) - start ))s"

TENANTS="$name" ./scripts/smoke.sh
