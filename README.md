# much. Odoo platform

A multi-tenant, self-hosted Odoo platform: one isolated Odoo + PostgreSQL per customer on Kubernetes, with
continuous backups, tested point-in-time restores, and alerting on silent failures. It runs locally on k3d,
and the same Terraform and Helm code targets a real cluster.

Design decisions, trade-offs and the 50 → 500+ customer path are in **[DESIGN.md](DESIGN.md)**.

```
browser ──► Traefik (TLS, cert-manager) ──► Odoo 18 ──► PgBouncer ──► PostgreSQL 17 (CloudNativePG)
              │  /websocket → :8072           │ filestore PVC            │ WAL + base backups
              │                               └─ rclone /15 min ─────────┴──► S3-compatible object storage
Prometheus ◄── blackbox probes, Postgres/PgBouncer metrics, Odoo cron metric ──► Alertmanager ──► on-call
                                                                  Watchdog ──► dead-man's switch
```

## Prerequisites

Docker, `k3d` ≥ 5.8, `kubectl`, `helm` 3, `terraform` ≥ 1.6, `make`, `curl`, `python3`.
About 6 GB of free RAM for two tenants plus the platform.

## Quick start

```bash
make up         # cluster + platform + every tenant in tenants.yaml (first run ~10 min, mostly image pulls)
make smoke      # end-to-end checks; exits non-zero on any failure
```

| URL | What |
|---|---|
| https://acme.localtest.me:8443 | tenant `acme` (user `admin` / `admin`) |
| https://globex.localtest.me:8443 | tenant `globex` |
| https://grafana.localtest.me:8443 | Grafana, dashboard "much. Odoo tenants" (`admin` / `make grafana-password`) |

Certificates come from a local CA, so the browser warns until you trust it:
`kubectl -n cert-manager get secret much-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > much-ca.crt`.

## Operations

| Command | What it does |
|---|---|
| `make up` | Converge everything to the code (idempotent; safe to re-run) |
| `make smoke` | Platform, security, backup, monitoring and per-tenant checks |
| `make onboard NAME=initech [SIZE=m]` | Add a customer: live, backed up and monitored in ~90 s |
| `make backup TENANT=acme` | On-demand base backup |
| `make restore-test TENANT=acme` | Restore drill: restores the latest backup into a throwaway namespace, verifies data, prints RTO |
| `make failover TENANT=acme` | Kill the Postgres primary under live traffic (needs `instances: 2`) |
| `make down` | Destroy the cluster |

### Customers

Customers are data, in [`tenants.yaml`](tenants.yaml):

```yaml
acme:
  size: s          # s | m  -> namespace quota
  instances: 2     # Postgres primary + streaming replica, automatic failover
globex:
  size: s
  restore: "2026-11-13T14:20:38Z"   # point-in-time restore (see below)
```

### Restoring a customer to a point in time

1. Add `restore: "<UTC timestamp>"` to the tenant in `tenants.yaml` and run `make up`.
2. A new cluster `<tenant>-db-restore` is recovered from object storage to that second. Odoo is switched to it
   through the tenant's `db` Service and restarted. The original database is kept for forensics.
3. `make smoke` confirms the tenant is healthy on the restored database.

Attachments are restored separately from `s3://backups/<tenant>/filestore` (and `filestore-history/` for
overwritten or deleted files). See DESIGN.md for the consistency gap between the two.

## Repository layout

```
tenants.yaml              customer list (the only file onboarding touches)
terraform/                cluster, platform layer, tenant module
  modules/tenant/         namespace, quota, secrets, Helm release per customer
  values/                 values for third-party charts
charts/tenant/            Odoo + CNPG cluster/pooler + backups + policies + monitoring for one customer
charts/platform/          local CA issuers, in-cluster DNS for tenant hostnames
charts/objectstore/       S3-compatible backup storage (local stand-in for a provider bucket)
charts/monitoring/        alert rules, Grafana dashboard, local alert receiver
scripts/                  smoke, backup, restore drill, demo scripts
.github/workflows/ci.yml  lint, schema validation, end-to-end on k3d
```
