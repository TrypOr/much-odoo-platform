#!/usr/bin/env bash
# Restore drill: prove a tenant's latest backup restores into a working database.
source "$(dirname "$0")/lib.sh"

t="${1:?usage: restore-test.sh <tenant>}"
ns="restore-drill-$t"
db="$(kubectl -n "$t" get svc db -o jsonpath='{.metadata.annotations.much\.io/db-cluster}')"
primary="$(kubectl -n "$t" get cluster "$db" -o jsonpath='{.status.currentPrimary}')"
store="$(kubectl -n "$t" get objectstore "$t-backups" -o jsonpath='{.spec.configuration.destinationPath} {.spec.configuration.endpointURL}')"
read -r dest endpoint <<<"$store"
q() { kubectl -n "$t" exec "$primary" -c postgres -- psql -U postgres -d odoo -v ON_ERROR_STOP=1 -tAc "$1"; }
# shellcheck disable=SC2329  # invoked via trap
cleanup() { kubectl delete ns "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "1/5 Write a canary to $t ($db)"
canary="drill-$(date +%s)"
q "create table if not exists restore_canary(note text, at timestamptz default now())" >/dev/null
q "insert into restore_canary(note) values ('$canary')" >/dev/null
users="$(q 'select count(*) from res_users')"
seg="$(q 'select pg_walfile_name(pg_switch_wal())')"

log "2/5 Wait until WAL $seg is archived"
for _ in $(seq 1 60); do
  [ "$(q "select coalesce(last_archived_wal >= '$seg', false) from pg_stat_archiver")" = t ] && break
  sleep 2
done
check "WAL $seg archived" t "$(q "select coalesce(last_archived_wal >= '$seg', false) from pg_stat_archiver")"

log "3/5 Restore $db from object storage into namespace $ns"
kubectl delete ns "$ns" --ignore-not-found >/dev/null
kubectl create ns "$ns" >/dev/null
# shellcheck disable=SC2016  # go-template, not shell
kubectl -n "$t" get secret backup-s3 -o go-template='{{range $k,$v := .data}}{{$k}}={{$v | base64decode}}{{"\n"}}{{end}}' \
  | kubectl -n "$ns" create secret generic backup-s3 --from-env-file=/dev/stdin >/dev/null
start=$(date +%s)
kubectl -n "$ns" apply -f - >/dev/null <<YAML
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: origin
spec:
  configuration:
    destinationPath: $dest
    endpointURL: $endpoint
    s3Credentials:
      accessKeyId: { name: backup-s3, key: ACCESS_KEY_ID }
      secretAccessKey: { name: backup-s3, key: ACCESS_SECRET_KEY }
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: drill
spec:
  instances: 1
  imageName: $(kubectl -n "$t" get cluster "$db" -o jsonpath='{.spec.imageName}')
  storage: { size: 2Gi }
  bootstrap:
    recovery:
      source: origin
      database: odoo
      owner: odoo
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters: { barmanObjectName: origin, serverName: $db }
YAML
kubectl -n "$ns" wait cluster/drill --for=jsonpath='{.status.phase}'="Cluster in healthy state" --timeout=600s >/dev/null || true
rto=$(( $(date +%s) - start ))

log "4/5 Verify restored data"
r() { kubectl -n "$ns" exec drill-1 -c postgres -- psql -U postgres -d odoo -tAc "$1" 2>/dev/null || true; }
check "restored cluster healthy" "Cluster in healthy state" "$(kubectl -n "$ns" get cluster drill -o jsonpath='{.status.phase}')"
check "canary present after restore" 1 "$(r "select count(*) from restore_canary where note='$canary'")"
check "odoo users intact ($users)" "$users" "$(r 'select count(*) from res_users')"

log "5/5 Verify filestore backup"
files="$(kubectl -n "$ns" run rclone --image=rclone/rclone:1.71.2 --restart=Never --rm -i --quiet \
  --env=RCLONE_CONFIG_S3_TYPE=s3 --env=RCLONE_CONFIG_S3_PROVIDER=SeaweedFS --env="RCLONE_CONFIG_S3_ENDPOINT=$endpoint" \
  --env="RCLONE_CONFIG_S3_ACCESS_KEY_ID=$(kubectl -n "$ns" get secret backup-s3 -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d)" \
  --env="RCLONE_CONFIG_S3_SECRET_ACCESS_KEY=$(kubectl -n "$ns" get secret backup-s3 -o jsonpath='{.data.ACCESS_SECRET_KEY}' | base64 -d)" \
  -- lsf -R --files-only "s3:${dest#s3://}/filestore" 2>/dev/null | grep -c . || true)"
check "filestore backup has files" yes "$([ "${files:-0}" -gt 0 ] && echo yes || echo no)"

log "RTO: database restored and verified in ${rto}s"
exit "$fail"
