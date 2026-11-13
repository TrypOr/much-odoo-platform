#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

t="${1:?usage: backup.sh <tenant>}"
db="$(kubectl -n "$t" get svc db -o jsonpath='{.metadata.annotations.much\.io/db-cluster}')"
name="$db-manual-$(date +%Y%m%d%H%M%S)"

log "On-demand backup $name"
kubectl -n "$t" apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $name
spec:
  cluster: { name: $db }
  method: plugin
  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }
YAML
kubectl -n "$t" wait backup "$name" --for=jsonpath='{.status.phase}'=completed --timeout=300s
