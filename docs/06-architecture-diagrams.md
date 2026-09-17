# 06 — Architecture Diagrams (per module)

All diagrams are [Mermaid](https://mermaid.js.org/) and render natively on GitHub/GitLab. If your
viewer doesn't render Mermaid, paste the block into <https://mermaid.live>.

This doc complements the theory docs (`01`–`03`) and the SOPs (`04`) with one diagram per module,
plus the two operational flows (`one-click-deploy.sh` and `teardown.sh`) laid out as flowcharts so
you can see exactly what each command does before you run it.

---
## 1. Full system topology

Everything below runs inside a **single Minikube node**, split across four namespaces
(`cnpg-system`, `tars-db`, `tars-db-dr`, `minio`, `tars-common`). This is the picture to hold in
your head for the whole POC.

```mermaid
flowchart TB
    subgraph host["CentOS 9 host — single-node Minikube"]
        subgraph cnpgsys["ns: cnpg-system"]
            operator["CNPG Operator\n(cluster-scoped controller)"]
            barmanplugin["Barman Cloud CNPG-I plugin"]
        end

        subgraph tarsdb["ns: tars-db"]
            primary["tarsdb-primary-1\nPRIMARY (read/write)"]
            replica["tarsdb-primary-2\nREPLICA (async streaming, read-only)"]
            pooler["Pooler: tarsdb-pgbouncer\n(pgBouncer, session mode)"]
            primary == "async streaming replication" ==> replica
        end

        subgraph miniosys["ns: minio"]
            bucket[("MinIO\nbucket: postgresbackup")]
        end

        subgraph tarsdbdr["ns: tars-db-dr"]
            dr["tarsdb-dr-1\nReplica Cluster\n(continuous WAL replay)"]
        end

        subgraph tarscommon["ns: tars-common"]
            monitor["CronJob: conn-monitor\n(threshold alert + idle reaper)"]
        end

        client(["Client / psql / app"])

        client -- "direct" --> primary
        client -- "pooled" --> pooler
        pooler --> primary

        primary -- "WAL archive push +\nweekly base backup" --> bucket
        bucket -- "bootstrap +\ncontinuous WAL restore" --> dr

        operator -. manages .-> primary
        operator -. manages .-> replica
        operator -. manages .-> dr
        operator -. manages .-> pooler
        monitor -. "psql: pg_stat_activity" .-> primary
    end
```

**Read it as:** one primary accepting writes, one same-site async replica for fast local failover,
a pooler in front for bursty workloads, everything continuously backed up to MinIO, and a
second `Cluster` (`tarsdb-dr`) in its own namespace that treats that same MinIO bucket as its
*only* source of truth — it never talks to the primary directly. See `docs/02-backup-dr-theory.md`
for why that matters.

---
## 2. Module: Primary HA cluster (`tarsdb-primary`)

```mermaid
flowchart LR
    subgraph cluster["Cluster: tarsdb-primary (instances: 2)"]
        p1["tarsdb-primary-1\nrole: primary\naccepts read/write"]
        p2["tarsdb-primary-2\nrole: replica\nasync streaming, read-only"]
        p1 == "WAL stream (async)" ==> p2
    end
    svc_rw["Svc: tarsdb-primary-rw"] --> p1
    svc_ro["Svc: tarsdb-primary-ro"] --> p2
    svc_r["Svc: tarsdb-primary-r\n(any instance)"] --> p1
    svc_r --> p2
    operator["CNPG instance manager\n(in every pod)"] -. "health checks,\nleader election via K8s API\n— no external DCS" .-> p1
    operator -. "automatic failover\npromotion on primary loss" .-> p2
```

`-rw` always points at the current primary (follows failover), `-ro` always points at replicas
only, `-r` load-balances across any ready instance. Point read-heavy/reporting workloads at `-ro`.

---
## 3. Module: Backup & DR (Barman Cloud + MinIO + replica cluster)

```mermaid
flowchart TB
    primary["tarsdb-primary\n(tars-db)"]
    plugin["Barman Cloud CNPG-I plugin\n(sidecar in each instance pod)"]
    objstore["ObjectStore CR\ntarsdb-primary-store"]
    bucket[("MinIO bucket\npostgresbackup")]
    sched["ScheduledBackup\ntarsdb-weekly-full\ncron: 0 0 22 * * 0 (Sun 22:00)"]
    dr["tarsdb-dr\nReplica Cluster (tars-db-dr)"]
    pitr["Scratch Cluster\ntarsdb-pitr-restore\n(SOP-5, created on demand)"]

    primary -- "continuous WAL push" --> plugin
    sched -- "triggers weekly" --> plugin
    plugin -- "archive-push / base backup" --> objstore
    objstore --> bucket

    bucket -- "bootstrap.recovery.source\n(initial base backup)" --> dr
    bucket -- "archive-get\n(continuous WAL replay)" --> dr
    bucket -- "recoveryTarget.targetTime" --> pitr
```

Retention is 14 days, matching the TARS PITR window (`docs/02-backup-dr-theory.md`). The DR
cluster's link to the primary is **entirely through the bucket** — it has no network path to
`tarsdb-primary` at all, which is exactly what makes it survive a primary-site network outage.

---
## 4. Module: Connection pooling (pgBouncer via CNPG `Pooler`)

```mermaid
flowchart LR
    appDirect["Apps: direct-connect workloads\n(most services)"]
    appPooled["Apps: bursty / short-lived-connection\nworkloads (tars-async-service,\ntars-bulk-service, ...)"]
    rw["Svc: tarsdb-primary-rw"]
    poolerSvc["Svc: tarsdb-pgbouncer\n(Pooler, poolMode: session)"]
    primary["tarsdb-primary-1 (PRIMARY)"]

    appDirect --> rw --> primary
    appPooled --> poolerSvc
    poolerSvc -- "max_client_conn=500\ndefault_pool_size=25" --> primary
```

Two independent paths to the same primary — pick per-workload, exactly like TARS's connection
matrix (`docs/03-connection-pooling-theory.md`). Pooling is opt-in per app, not a mandatory proxy
in front of everything.

---
## 5. Module: Connection monitoring (threshold alert + idle reaper)

```mermaid
flowchart LR
    cron["CronJob: conn-monitor\nschedule: */10 * * * *"]
    job["Job pod\nscripts/monitor/conn_monitor.py"]
    pg["tarsdb-primary-1\npg_stat_activity"]
    alert["Alert (log/email)\nif connections > 68% of max_connections"]
    reaper["Idle reaper\nterminates sessions idle > 5 min"]

    cron --> job
    job -- "psql query" --> pg
    job --> alert
    job --> reaper
    reaper -- "pg_terminate_backend()" --> pg
```

68% is TARS's own alert ratio (170/250 in TARS's sizing), recomputed here against this POC's
reduced `max_connections=50` — see `docs/03-connection-pooling-theory.md`'s alerting section for
why the threshold is set below the hard ceiling instead of at it.

---
## 6. Flow: `./one-click-deploy.sh` (setup)

```mermaid
flowchart TD
    start(["./one-click-deploy.sh [flags]"]) --> s1["1. OS prereqs\n00-prereqs-centos9.sh"]
    s1 --> s2["2. Docker\n01-install-docker.sh"]
    s2 --> s3["3. Minikube + kubectl + namespaces\n02-install-minikube-kubectl.sh"]
    s3 --> s4["4. CNPG operator + Barman plugin\n03-install-cnpg-operator.sh"]
    s4 --> s4b{"--with-edb ?"}
    s4b -- yes --> s4c["4b. EDB registry secret\nsetup-edb-registry.sh (interactive)"]
    s4b -- no --> s5
    s4c --> s5["5. Generate secrets\ngenerate-secrets.sh -> credentials.txt"]
    s5 --> s6["6. Deploy MinIO\n04-deploy-minio.sh"]
    s6 --> s7["7. Create postgresbackup bucket\n05-create-minio-buckets.sh (retried x5)"]
    s7 --> s8["8. Primary HA cluster\n+ initial Barman backup\n06-deploy-primary-cluster.sh"]
    s8 --> s9["9. pgBouncer Pooler\n07-deploy-pooler.sh"]
    s9 --> s10["10. DR replica cluster\n08-deploy-dr-replica-cluster.sh"]
    s10 --> s11["11. Connection monitor CronJob"]
    s11 --> s12{"--with-test-data ?"}
    s12 -- yes --> s12a["12. Load schema + 100k rows\n09-load-test-data.sh"]
    s12 -- no --> done
    s12a --> done(["Deployment complete\ncredentials.txt + one-click-deploy.log"])
```

Every step is idempotent (`kubectl apply` or an existence check first), so re-running after a
partial failure resumes rather than duplicates work — see "One-click deploy" in the README.

---
## 7. Flow: `./teardown.sh [--full]`

```mermaid
flowchart TD
    start(["./teardown.sh [--full]"]) --> confirm{"Confirm? [y/N]"}
    confirm -- N --> abort(["Aborted — nothing changed"])
    confirm -- y --> d1["delete ObjectStores\n(tars-db, tars-db-dr)"]
    d1 --> d2["delete Clusters\ntarsdb-primary, tarsdb-dr"]
    d2 --> d3["delete Pooler\ntarsdb-pgbouncer"]
    d3 --> d4["delete ScheduledBackup\ntarsdb-weekly-full"]
    d4 --> d5["delete CronJob\nconn-monitor"]
    d5 --> d6["delete MinIO Deployment + PVC"]
    d6 --> full{"--full ?"}
    full -- no --> done1(["Namespaces/CRDs cleared.\nMinikube VM + credentials.txt kept"])
    full -- yes --> d7["minikube delete\n(destroys the whole VM)"]
    d7 --> done2(["Everything gone.\nNext run starts from scratch"])
```

**Known gap:** every delete in the flow above is a live `kubectl` call, so `teardown.sh` needs a
*reachable* API server. If Minikube itself is already `Stopped` (not just idle), `kubectl` can't
connect and the script exits immediately on the first delete (it runs under `set -euo pipefail`).
In that state, skip straight to `minikube delete` (or `minikube start` first if you want the
resource-by-resource teardown log) — see "Troubleshooting" in the README.
