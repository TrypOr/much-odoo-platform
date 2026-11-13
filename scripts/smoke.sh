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

check "object storage available" True "$(kubectl -n objectstore get deploy s3 \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"

log "Monitoring"
check "prometheus ready" True "$(kubectl -n monitoring get prometheus kps-kube-prometheus-stack-prometheus -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
check "grafana via https" 200 "$(curl -s --cacert "$CA" --resolve grafana.localtest.me:8443:127.0.0.1 -o /dev/null -w '%{http_code}' --max-time 10 https://grafana.localtest.me:8443/api/health || true)"
check "alert rules loaded" 3 "$(prom 'count(count by (rule_group) (prometheus_rule_group_rules{rule_group=~".*much.*"}))')"
deadman="$(kubectl -n monitoring logs deploy/alert-sink --since=15m 2>/dev/null | grep -c 'POST /deadman' || true)"
check "dead-man switch delivering" yes "$([ "${deadman:-0}" -gt 0 ] && echo yes || echo no)"

for t in $TENANTS; do
    log "Tenant $t"
    db="$(kubectl -n "$t" get svc db -o jsonpath='{.metadata.annotations.much\.io/db-cluster}' 2>/dev/null || true)"
    db="${db:-$t-db}"
    check "$t db healthy" "Cluster in healthy state" "$(kubectl -n "$t" get cluster "$db" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    pw="$(kubectl -n "$t" get secret odoo-db -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
    check "$t sql via pooler" 1 "$(kubectl -n "$t" exec deploy/odoo -c odoo -- env PGPASSWORD="$pw" \
      psql -h db -U odoo -d odoo -tAc 'select 1' 2>/dev/null || true)"

    cond() { kubectl -n "$t" get cluster "$db" -o jsonpath="{.status.conditions[?(@.type==\"$1\")].status}" 2>/dev/null || true; }
    archiver="$(kubectl -n "$t" get cluster "$db" -o jsonpath='{.spec.plugins[?(@.isWALArchiver==true)].name}' 2>/dev/null || true)"
    check "$t WAL archived to object storage" "barman-cloud.cloudnative-pg.io/True" "$archiver/$(cond ContinuousArchiving)"
    rw() { kubectl -n "$t" get objectstore "$t-backups" -o jsonpath="{.status.serverRecoveryWindow['$db'].$1}" 2>/dev/null || true; }
    check "$t recovery window exists" yes "$([ -n "$(rw firstRecoverabilityPoint)" ] && echo yes || echo no)"
    check "$t last backup succeeded" True "$(cond LastBackupSucceeded)"
    check "$t probed from outside" 1 "$(prom "probe_success{job=\"odoo-login\",tenant=\"$t\"}")"
    check "$t postgres metrics scraped" 1 "$(prom "max(up{namespace=\"$t\",container=\"postgres\"})")"
    # shellcheck disable=SC2143  # grep -q would SIGPIPE kubectl and fail under pipefail
    check "$t filestore backup has run" yes "$([ -n "$(kubectl -n "$t" get jobs -o jsonpath='{range .items[?(@.status.succeeded==1)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep filestore-backup)" ] && echo yes || echo no)"

    check "$t odoo login page" 200 "$(odoo_http "$t" /web/login)"
    manager="$(odoo_body "$t" /web/database/manager)"
    check "$t db manager disabled" 1 "$(grep -c 'disabled by the administrator' <<<"$manager" || true)"

    h="$t.localtest.me"; R=(--resolve "$h:8443:127.0.0.1")
    check "$t https login" 200 "$(curl -s --cacert "$CA" "${R[@]}" -o /dev/null -w '%{http_code}' --max-time 10 \
      "https://$h:8443/web/login" || true)"
    check "$t websocket upgrade" 101 "$(curl -sk --http1.1 "${R[@]}" -o /dev/null -w '%{http_code}' --max-time 3 \
      -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
      -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H "Origin: https://$h:8443" \
      "https://$h:8443/websocket" || true)"

    spec="$(kubectl -n "$t" get deploy odoo -o jsonpath='{.spec.template.spec.securityContext.runAsNonRoot}/{.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem}/{.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation}' 2>/dev/null || true)"
    check "$t odoo enforced non-root/read-only/no-escalation" "true/true/false" "$spec"
    check "$t odoo cannot bypass pooler" blocked "$(can_connect "$t" "$db-rw")"
    for o in $TENANTS; do
      [ "$o" = "$t" ] && continue
      check "$t cannot reach $o database" blocked "$(can_connect "$t" "db.$o")"
    done
    
done

exit "$fail"
