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

CA="$(mktemp)"
trap 'rm -f "$CA"' EXIT
kubectl -n cert-manager get secret much-ca -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "$CA" || true

for t in $TENANTS; do
    log "Tenant $t"
    check "$t db healthy" "Cluster in healthy state" "$(kubectl -n "$t" get cluster "$t-db" -o jsonpath='{.status.phase}' 2>/dev/null ||
  true)"
    pw="$(kubectl -n "$t" get secret odoo-db -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
    check "$t sql via pooler" 1 "$(kubectl -n "$t" exec "$t-db-1" -c postgres -- env PGPASSWORD="$pw" \
    psql -h "$t-pooler-rw" -U odoo -d odoo -tAc 'select 1' 2>/dev/null || true)"

    check "$t odoo login page" 200 "$(odoo_http "$t" /web/login)"
    check "$t db manager disabled" 1 "$(kubectl -n "$t" exec deploy/odoo -c odoo -- python3 -c \
    "import urllib.request;print(int('disabled by the administrator' in
    urllib.request.urlopen('http://localhost:8069/web/database/manager').read().decode()))" 2>/dev/null || true)"

    h="$t.localtest.me"; R=(--resolve "$h:8443:127.0.0.1")
    check "$t https login" 200 "$(curl -s --cacert "$CA" "${R[@]}" -o /dev/null -w '%{http_code}' --max-time 10 \
      "https://$h:8443/web/login" || true)"
    check "$t websocket upgrade" 101 "$(curl -sk --http1.1 "${R[@]}" -o /dev/null -w '%{http_code}' --max-time 3 \
      -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
      -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H "Origin: https://$h:8443" \
      "https://$h:8443/websocket" || true)"
done

exit "$fail"