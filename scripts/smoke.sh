#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

log "Cluster"
check "nodes ready" 2 "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)"

log "Platform"
check "cnpg operator available" True "$(kubectl -n cnpg-system get deploy -l app.kubernetes.io/name=cloudnative-pg \
-o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"

check "barman plugin available" True "$(kubectl -n cnpg-system get deploy -l app.kubernetes.io/name=plugin-barman-cloud \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"

check "cert-manager available" True "$(kubectl -n cert-manager get deploy cert-manager \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"

for t in $TENANTS; do
    log "Tenant $t"
    check "$t db healthy" "Cluster in healthy state" "$(kubectl -n "$t" get cluster "$t-db" -o jsonpath='{.status.phase}' 2>/dev/null ||
  true)"
    pw="$(kubectl -n "$t" get secret odoo-db -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
    check "$t sql via pooler" 1 "$(kubectl -n "$t" exec "$t-db-1" -c postgres -- env PGPASSWORD="$pw" \
      psql -h "$t-pooler-rw" -U odoo -d odoo -tAc 'select 1' 2>/dev/null || true)"
done

exit "$fail"