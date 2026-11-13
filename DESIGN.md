# DESIGN

How this platform is built, why, what I proved by breaking it, and how it grows from 50 to 500+ customers.

## 1. Context and assumptions

- much. hosts Odoo for its clients and is moving off managed hosting onto its own infrastructure.
- **Each client is a separate company**: separate data, separate modules, its own upgrade timing. So one
  client must never see, slow down or break another.
- The cloud provider is unknown. Everything that touches storage speaks the **S3 API**, so the provider is a
  configuration detail (Hetzner, OVH, Scaleway, AWS, Ceph…).
- Reviewers must be able to run it with Docker only, so the reference environment is **k3d** (Kubernetes in
  Docker). The same Terraform modules and Helm charts deploy unchanged to a real cluster.
- Official Odoo image, Community edition, pinned: `odoo:18.0-20261102`. PostgreSQL 17 (Odoo 18 isn't
  validated on 18 yet).

## 2. Architecture

```
                      ┌─────────────────────────── k8s cluster ───────────────────────────┐
 browser ── HTTPS ──► │ Traefik ──► namespace "acme"                                      │
                      │   │          Odoo (1 pod, workers=2) ── db Service ── PgBouncer ── │──► PostgreSQL (CNPG)
                      │   │          /websocket → 8072                                     │      primary [+ replicas]
                      │   │          filestore PVC ── rclone every 15 min ──┐              │      │ WAL (seconds)
                      │   └─► namespace "globex" (same shape)               │              │      │ base backup (hourly)
                      │                                                     ▼              │      ▼
                      │  objectstore: S3-compatible bucket  ◄────────────────────────────── │
                      │  cert-manager · CNPG operator + Barman Cloud plugin                │
                      │  monitoring: Prometheus · Alertmanager · Grafana · blackbox        │
                      └────────────────────────────────────────────────────────────────────┘
```

Three layers, all in Terraform:

| Layer | Contents | Changes |
|---|---|---|
| Cluster | k3d locally (k3s / managed Kubernetes in production) | Rarely, deliberately |
| Platform | cert-manager, CloudNativePG + Barman Cloud plugin, object storage, monitoring, CA issuers | Per platform release |
| Tenants | one `tenant` module per entry in `tenants.yaml` | Every onboarding / resize / restore |

Terraform decides **what** each tenant gets (size, instances, restore point, credentials). The Helm chart
`charts/tenant` decides **how** that looks in Kubernetes. Customers are data in `tenants.yaml`, not code.

## 3. Tenancy model: one namespace, one Postgres per customer

Each customer gets a namespace containing its own Odoo, its own CloudNativePG cluster, its own PgBouncer,
secrets, NetworkPolicies, ResourceQuota/LimitRange, backup configuration and monitoring objects.

**Why a Postgres cluster per tenant rather than one big shared Postgres:**

- Isolation: a heavy report or bad import at one client can't starve another's queries.
- Restores are per customer. Point-in-time recovery restores a whole cluster, so with a shared cluster,
  restoring client A to 10:00 would roll back everyone.
- Upgrades, extensions and Postgres versions can differ per customer.
- Blast radius: a corrupted cluster or a leaked credential affects one client.

**Cost:** roughly 300–500 MB more memory per tenant than a shared database. For very small tenants a shared
cluster per "pod of 20 tenants" is a later cost optimisation; the module interface wouldn't change.

**Sizes** translate a commercial plan into limits (quota includes headroom for a restore, see §6):

| Size | requests.memory | limits.memory | storage |
|---|---|---|---|
| s | 3 Gi | 5 Gi | 10 Gi |
| m | 5 Gi | 8 Gi | 30 Gi |

## 4. Odoo configuration

- `workers = 2` (prefork, production mode) with the gevent/websocket server on 8072. The Ingress routes
  `/websocket` to 8072 and everything else to 8069. Getting this wrong is a silent failure (pages load, chat
  and notifications die), so it's tested end to end (expects `101 Switching Protocols`).
- `list_db = False`, `dbfilter = ^odoo$`, random master password per tenant. The database manager can dump or
  drop databases, so it's disabled, and the DB RPC API refuses requests (verified).
- `proxy_mode = True` behind Traefik; `limit_memory_soft/hard` recycle a worker before Kubernetes would
  OOM-kill the whole pod.
- **Config with secrets never touches disk.** The ConfigMap holds placeholders; an init container renders the
  real passwords from Secrets into a memory-backed `emptyDir`.
- **Database initialisation is idempotent.** The init container installs `base` only if it isn't installed.
  This is safe because there is exactly one replica with `strategy: Recreate`. With several replicas it moves
  to a single Job (Helm hook), see §10.
- Odoo connects to **our own `db` Service**, which points at the active cluster's PgBouncer. PgBouncer runs in
  **session** mode because Odoo relies on session-level Postgres features.

## 5. Security hardening

| Control | Where |
|---|---|
| Non-root enforced (`runAsNonRoot`), read-only root filesystem, all capabilities dropped, no privilege escalation, seccomp `RuntimeDefault` | Odoo, backup job, object storage, alert receiver; CNPG pods ship hardened |
| No Kubernetes API token mounted where not needed | `automountServiceAccountToken: false` |
| Default-deny ingress per tenant; explicit allows: Traefik → Odoo, Odoo → PgBouncer, PgBouncer/replicas/CNPG jobs → Postgres, CNPG operator → Postgres, monitoring → metrics | `charts/tenant/templates/networkpolicy.yaml` |
| Cross-tenant traffic blocked, and Odoo can't bypass PgBouncer | tested in `make smoke` |
| Secrets generated by Terraform (`random_password`), never in Git; sensitive values hidden from plan output | `terraform/` |
| TLS everywhere at the edge, certificates issued and renewed by cert-manager | Ingress annotation |
| Pinned versions for every chart, provider and image | reproducible tenants, controlled upgrades |
| Metrics user has read access to exactly one Odoo table (`ir_cron`) | least privilege |

The tests assert **policy, not behaviour**. My first "runs as non-root" test passed before I changed anything,
because the image already runs as uid 100. It now checks that Kubernetes *enforces* it, so a future image
change that runs as root is refused, not silently accepted.

**Production next steps:** secrets from an external store (External Secrets Operator + Vault or a cloud KMS,
or SOPS-encrypted in Git) and remote Terraform state with locking and encryption. Also egress
NetworkPolicies (the CNPG instance manager needs the API server allowed), Pod Security Admission
`restricted` on tenant namespaces, a WAF/rate limiting in front of `/web/login`, and HTTP→HTTPS redirect with
HSTS. The default Odoo `admin/admin` user login must be randomised at onboarding and handed to the customer.

## 6. Data persistence and backups

| Data | Mechanism | RPO |
|---|---|---|
| PostgreSQL | WAL streamed continuously by the Barman Cloud plugin + hourly base backup (prod: daily), 7-day retention, gzip | **seconds** |
| Filestore (attachments) | `rclone sync` every 15 min; changed or deleted files kept under `filestore-history/<timestamp>` | ≤ 15 min |
| Platform config and secrets | Terraform code + state | per change |

- Storage is S3-compatible object storage, one prefix per tenant (`s3://backups/<tenant>/…`).
- Locally the bucket is SeaweedFS (Apache-2.0, pinned). Postgres backups and the filestore job only know an
  S3 endpoint and keys, so moving to any provider's object storage changes configuration, not code.
- New tenants are backed up from minute one: onboarding triggers the first filestore backup and the first base
  backup (`immediate: true`).
- Volumes use the cluster's default StorageClass (local-path in k3d). In production this is replicated block
  storage (cloud volumes or Longhorn/Ceph). Backups don't rely on it.

**Production next steps:** a bucket and credential per tenant (today one shared credential, so a leak
exposes all backups); a second copy in another region or provider (3-2-1); object lock / immutability against
ransomware; client-side encryption.

## 7. Restores: proven, not assumed

**Procedure** (README has the steps): add `restore: "<timestamp>"` to the tenant and `make up`. CNPG
recovers a new cluster `<tenant>-db-restore` to that second from object storage; the `db` Service and Odoo
switch to it. The original cluster is untouched, so a wrong timestamp is never destructive and the broken state
is kept for forensics.

**Drill:** `make restore-test TENANT=x` runs these steps:
1. Writes a canary row.
2. Forces a WAL switch and waits until it's archived.
3. Restores the latest backup into a throwaway namespace.
4. Checks the canary and the Odoo users are present.
5. Checks the filestore backup exists.
6. Prints the RTO and cleans up.

CI runs it on every pull request.

**Measured:** RTO **57–60 s** for a fresh tenant (restore + verification). Real switch-over tested on
`globex`: a deleted row came back, Odoo served from the restored database, every smoke check green.

**Two bugs only an actual restore revealed:**
1. CNPG makes a Pooler's cluster reference **immutable**, so "repoint the pooler" was impossible. Fix: a
   pooler per cluster and our own stable `db` Service in front.
2. The tenant quota had **no headroom for a second database**, so the recovery job was rejected. Quotas now
   include restore capacity.

**Known gap:** the database restores to any second, attachments only to the last 15-minute sync. Production fix:
filestore on object storage (Odoo S3 attachment module) or volume snapshots taken with the base backup.

## 8. Observability

- **Black-box:** the blackbox exporter fetches each tenant's real login page every 30 s through Traefik
  (in-cluster DNS rewrites `*.localtest.me` to Traefik, so the probe takes the user's path) and records TLS
  expiry.
- **White-box:** CNPG and PgBouncer metrics via PodMonitors, kube-state-metrics, node-exporter, plus a custom
  SQL metric `cnpg_odoo_cron_oldest_due_seconds` (how overdue Odoo's scheduled actions are).
- **Grafana** dashboard "much. Odoo tenants" shows:
  - tenant up
  - backup age
  - WAL age
  - login latency
  - overdue crons
  - filestore backup age
  - connections
  - memory per tenant
  - firing alerts
- **Alertmanager** routes to on-call (a local webhook receiver stands in for PagerDuty/Slack). The Watchdog
  goes to a separate dead-man receiver every minute.
- Alerts carry a summary and a runbook command.

## 9. Silent failures

A silent failure is one where every dashboard is green and the data or service is not OK. These are the ones I
found or designed for, and how each is caught:

| Failure | Why it's silent | Detection |
|---|---|---|
| WAL archiving has no destination | CNPG reports **"Continuous archiving is working"** while WAL goes nowhere (found during build) | smoke asserts the archiver is the backup plugin **and** the object store reports a recovery window |
| Backup credentials broken / bucket unreachable | Postgres keeps serving normally | `WALArchivingFailing` (last attempt failed), `BackupStale`, `BackupFailed`. **Fault-injected**: alert pending after 37 s, fired and paged at 5 min; `terraform apply` healed the drifted secret |
| Backup-age metric always 0 | CNPG's standard `last_available_backup_timestamp` is 0 with plugin backups, so an alert on it never or always fires (found during build) | alerts use the plugin's `barman_cloud_…_last_available_backup_timestamp` |
| Filestore backups stop | DB backups look fine; attachments silently unprotected | `FilestoreBackupStale`, `FilestoreBackupJobFailed` |
| Backups exist but don't restore | Nothing fails until the day you need it | restore drill on every PR (`make restore-test`) |
| Odoo scheduled actions stuck (cron worker dead or disabled) | Web UI works; invoices, emails and reminders silently stop | `OdooCronStuck` on the most overdue `ir_cron.nextcall` |
| Websocket routed to the wrong port | Pages load; live chat/notifications dead | smoke expects `101` through the ingress |
| Certificate renewal failing | Fine until expiry day | `CertificateExpiringSoon` (< 14 days) from probes |
| Alerting pipeline dead | A dead Alertmanager looks exactly like a quiet, healthy platform | Watchdog → dead-man endpoint every minute; in production an external heartbeat service pages if it stops |
| Config drift (manual edits) | Cluster no longer matches Git | `terraform plan -detailed-exitcode` in CI; re-apply heals (demonstrated with the backup secret) |
| Archive alert on idle tenants | Naive "time since last WAL" pages for a quiet tenant (false positive found during build) | alert fires only when the most recent archive attempt failed |

## 10. High availability and scaling a tenant

**Postgres:** `instances: 2` in `tenants.yaml` adds a streaming replica; CNPG fails over automatically.
`make failover` deletes the primary under live traffic. Measured:

- **Default settings: ~3 minutes.** The dying primary waited CNPG's default 180 s smart shutdown for pooled
  Odoo connections that never close by themselves.
- **With `smartShutdownTimeout: 15`: promoted in 19 s**, ~15 s of requests got Odoo's "database unavailable"
  redirect, then service resumed with no intervention.
- Also found here: my default-deny NetworkPolicy blocked CNPG's replica *join* job (it isn't labelled as an
  instance). Policy now allows the tenant's own CNPG pods.
- Further: synchronous replication for zero data loss (costs write latency); PgBouncer pause/resume during
  switchover.

**Odoo horizontally:** deliberately one replica per tenant here. Running N Odoo pods needs:

1. **Shared filestore**: RWX volume or Odoo's S3 attachment storage (today the RWO volume forces `Recreate`).
2. **Shared sessions**: Odoo stores sessions on the filestore by default, so they need to live on the shared
   storage or in Redis or the DB.
3. **Crons in exactly one place**: `max_cron_threads=0` on web pods and a dedicated cron deployment, or
   Odoo's DB-level cron locking.
4. **Websocket routing**: `/websocket` to the gevent workers; sticky sessions are not required once sessions
   are shared.
5. **DB init and module upgrades** as a single Job/Helm hook, never in every pod.
6. Then an HPA on CPU/latency, and PgBouncer sized for N × workers connections.

For most SME tenants vertical sizing (`s`/`m`, more workers) is cheaper and simpler than N pods. The work above
is for the few large customers.

## 11. From 50 to 500+ customers

| Concern | 50 customers (this design) | 500+ customers |
|---|---|---|
| Customer list | `tenants.yaml` in Git | Same data model, generated from the CRM/billing system; a PR per change |
| Delivery | `make up` / Terraform | GitOps: Argo CD `ApplicationSet` renders one tenant per entry; Terraform only for clusters and platform |
| Clusters | one | several clusters ("cells") of ~100–150 tenants, per region; blast radius and upgrade unit = one cell |
| Upgrades | all tenants at once | chart/image version **per tenant**; canary tenants → waves → all, watching error rates between waves. Chart versions are already bumped on every change for this reason |
| Terraform state | local file | remote backend with locking (S3-compatible + lock), one state per cell, cluster state separate from tenants, `prevent_destroy` on stateful resources |
| Postgres | one cluster per tenant | same; very small tenants pooled into shared clusters per cell for cost |
| Backups | one bucket, shared key | bucket + key per tenant, cross-region copy, immutability |
| Monitoring | one Prometheus, 24 h | Prometheus per cell + long-term store (Thanos/Mimir), central Alertmanager, SLOs per tenant |
| Logs | `kubectl logs` | Loki (or ELK) with per-tenant labels |
| On-call | webhook stand-in | PagerDuty/Opsgenie with severity routing and runbooks linked from alerts |
| Cost | — | per-tenant resource usage from labels feeds pricing of `s`/`m` plans |

Onboarding is already the 500-customer shape: one line of data, ~90 s to live, backed up and monitored, with no
human steps.

## 12. CI/CD

Every PR runs:
- `terraform fmt`/`validate`
- `helm lint`
- **kubeconform** against Kubernetes 1.35 and the real CRD schemas (CNPG, Barman, Prometheus Operator,
  cert-manager)
- **shellcheck**
- an **end-to-end** job that builds the whole platform on a fresh runner, runs `make smoke` and
  `make restore-test`, and fails if a second `terraform plan` would change anything

Production adds a `terraform plan` against the real environment posted on the PR, and staged rollout after
merge.

## 13. Things that went wrong while building (and what they taught)

- **A whitespace change destroyed the cluster.** `triggers_replace` on the k3d config hash replaced the whole
  cluster after a line-ending fix. Lesson: always read the plan before applying; cluster lifecycle is
  separate and deliberate.
- **Terraform didn't see chart changes.** The Helm provider compares chart *version* and values, not template
  files. Every chart change now bumps its version, which is also what enables per-tenant rollouts.
- **A green status that lied** (WAL archiving without a destination), a **metric that's always 0** (plugin
  backups) and a **false alarm on idle tenants**. Lesson: alert on the outcome (a recoverable window exists,
  the last attempt succeeded), not on a component's opinion of itself.
- **Restores and failovers found three bugs no unit test would:**
  - an immutable pooler reference
  - quota without restore headroom
  - a NetworkPolicy blocking replica creation

  Lesson: practise the disaster.
- **WSL2 clock jitter** made a default Alertmanager crash-loop rule fire with zero restarts. I disabled it,
  documented why, and crash loops are still caught by restart counts.

## 14. Known gaps (prioritised)

1. One shared backup credential/bucket → per-tenant buckets and keys, cross-region copy.
2. Filestore restore granularity (15 min) vs database (seconds).
3. Secrets in Terraform state → external secret store, encrypted remote state.
4. No log aggregation (Loki) and single-replica Prometheus.
5. No egress NetworkPolicies / Pod Security Admission labels yet.
6. Restore drill verifies data in SQL. Next: boot a throwaway Odoo against the restored DB and run it on a
   schedule with an alert.
7. No PVC usage alerts (local-path volumes don't report usage; node filesystem alerts cover the host).

## 15. Tooling note

I used Claude (AI) as a pairing partner and reviewer throughout, as encouraged in the brief. Every component
was run, broken on purpose and verified on my machine, and the measurements above come from those runs.
