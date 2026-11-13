#!/usr/bin/env bash
# Demo: kill a tenant's Postgres primary under live traffic and measure the impact.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

t="${1:?usage: failover.sh <tenant>}"
db="$(kubectl -n "$t" get svc db -o jsonpath='{.metadata.annotations.much\.io/db-cluster}')"
instances="$(kubectl -n "$t" get cluster "$db" -o jsonpath='{.spec.instances}')"
[ "$instances" -ge 2 ] || { echo "$t has $instances instance(s); set 'instances: 2' in tenants.yaml and make up first"; exit 1; }

kubectl -n "$t" get pods -l cnpg.io/cluster="$db" -L role
old="$(kubectl -n "$t" get cluster "$db" -o jsonpath='{.status.currentPrimary}')"
url="https://$t.localtest.me:8443/web/login"
results="$(mktemp)"; trap 'rm -f "$results"' EXIT

log "Sending a request every 0.5s to $url"
( end=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    printf '%s %s\n' "$(date +%T)" "$(curl -sk --resolve "$t.localtest.me:8443:127.0.0.1" -o /dev/null -w '%{http_code}' --max-time 3 "$url" || echo 000)" >> "$results"
    sleep 0.5
  done ) &
loop=$!
sleep 5

log "Deleting primary $old at $(date +%T)"
kubectl -n "$t" delete pod "$old" --wait=false
for _ in $(seq 1 60); do
  new="$(kubectl -n "$t" get cluster "$db" -o jsonpath='{.status.currentPrimary}')"
  [ -n "$new" ] && [ "$new" != "$old" ] && break
  sleep 1
done
log "New primary: $new at $(date +%T)"
wait "$loop"

ok=$(grep -c ' 200$' "$results" || true); total=$(wc -l < "$results")
log "Requests: $ok/$total succeeded during the failover"
if [ "$ok" -lt "$total" ]; then
  first=$(grep -v ' 200$' "$results" | head -1 | cut -d' ' -f1); last=$(grep -v ' 200$' "$results" | tail -1 | cut -d' ' -f1)
  log "Errors from $first to $last; status codes: $(grep -v ' 200$' "$results" | cut -d' ' -f2 | sort | uniq -c | tr -s ' ' | tr '\n' ',')"
fi
kubectl -n "$t" get pods -l cnpg.io/cluster="$db" -L role
