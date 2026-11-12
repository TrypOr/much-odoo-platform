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

exit "$fail"