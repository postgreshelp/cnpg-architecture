# 01 — Architecture & Theory: TARS-on-CloudNativePG

## 1. Why CloudNativePG (CNPG) instead of Crunchy PGO / hand-rolled Patroni

The source TARS platform runs PostgreSQL 15.6 under the **Crunchy PostgreSQL Operator (PGO)**,
which composes Patroni (HA/failover), pgBackRest (backup/WAL archiving/DR), and pgBouncer
(pooling) as separate sidecars/pods glued together by the operator.

**CloudNativePG (CNPG)**, a CNCF project, collapses
that stack into a single Kubernetes-native operator:

| Concern | Crunchy PGO stack | CloudNativePG |
|---|---|---|
| HA / failover orchestration | Patroni + etcd/K8s API as DCS | Built into the CNPG **instance manager** (no external DCS — it uses the K8s API directly as the source of truth, same principle as Patroni's K8s DCS mode, but native) |
| Backup / WAL archive / PITR | pgBackRest, `stanza db`, repo1 (local) + repo2 (S3) | **Barman Cloud CNPG-I plugin** for object-store backup/WAL/PITR; this POC uses the MinIO repository as the remote backup/DR store |
| Connection pooling | pgBouncer, managed by PGO | pgBouncer, managed natively via the CNPG **Pooler** CRD |
| DR / secondary site | Manual pgBackRest restore + Patroni standby.signal wiring | **Replica Cluster** — a first-class CNPG feature: a second `Cluster` object that bootstraps from the same object store and continuously replays WAL, promotable with a single field flip |
| Monitoring | Prometheus scrape of custom exporters | Built-in `/metrics` endpoint + `PodMonitor` CRD, same `pg_stat_statements`/`pgaudit` style extensions supported |

For the core database/HA/DR topology this is a 1:1 replacement: same PostgreSQL major version family, same
streaming-replication/async-HA/PITR-DR shape as the TARS document, just orchestrated by a
different (and, for new builds, generally preferred/simpler-to-operate) operator.

## 2. Target topology (what you're building)

> The ASCII diagram below is the quick reference. For a Mermaid version of this same picture plus
> a dedicated diagram per module (primary HA, backup/DR, pooling, monitoring) and flowcharts for
> `one-click-deploy.sh`/`teardown.sh`, see **`docs/06-architecture-diagrams.md`**.

```
                     ┌───────────────────────────────────────────────┐
                     │            Minikube (CentOS 9 host)            │
                     │                                                │
  Client / psql      │   ns: tars-db                                  │
  ────────────►      │   ┌───────────────────────────────────────┐   │
                      │   │ CNPG Operator (cluster-scoped)         │   │
                      │   └───────────────────────────────────────┘   │
                      │   ┌───────────────────────────────────────┐   │
                      │   │ Cluster "tarsdb-primary" (instances:2) │   │
                      │   │   pod 0: role=primary  (read/write)    │   │
                      │   │   pod 1: role=replica  (streaming,     │──┐│
                      │   │           async, read-only)            │  ││
                      │   └───────────────────────────────────────┘  ││
                      │   ┌───────────────────────────────────────┐  ││
                      │   │ Pooler "tarsdb-pgbouncer" (pgbouncer)  │  ││
                      │   │   svc: tarsdb-pgbouncer:5432           │  ││
                      │   └───────────────────────────────────────┘  ││
                      │                                               ││
                      │   ns: minio                                   ││ archive-push
                      │   ┌───────────────────────────────────────┐  ││ (WAL + base backups)
                      │   │ MinIO (S3-compatible object store)     │◄─┘│
                      │   │   bucket: postgresbackup                 │
                      │   └───────────────────────────────────────┘  │
                      │                    ▲ archive-get / restore   │
                      │                    │ (continuous WAL replay) │
                      │   ns: tars-db-dr   │                         │
                      │   ┌────────────────┴──────────────────────┐ │
                      │   │ Cluster "tarsdb-dr" (replica cluster)  │ │
                      │   │   instances:1, replica.enabled=true    │ │
                      │   │   bootstraps from object store,        │ │
                      │   │   continuously replays WAL — NOT       │ │
                      │   │   streaming directly from primary      │ │
                      │   └─────────────────────────────────────────┘│
                      └───────────────────────────────────────────────┘
```

This is functionally the same shape as page 2 of the TARS PDF (Site 1 hciprod primary +
async replica, repo2 MinIO, Site 2 hcidr standby fed via `archive-get` from the repo, not
direct streaming) — just realized as two `Cluster` CRs in two namespaces on one Minikube
instead of two OpenShift clusters.

## 3. Core theory you should know before you run this

**Streaming replication (async).** The primary ships WAL records to standbys over a normal
libpq connection as soon as they're generated (`walsender`/`walreceiver`), the standby applies
them and confirms — but the primary does **not** wait for that confirmation before committing
locally. This is why TARS lists `Mode: Asynchronous` — it favors primary commit latency over
zero-data-loss guarantees on failover (some recent transactions can be lost if the primary dies
before shipping their WAL). CNPG defaults to async streaming between primary/replica within a
`Cluster`, matching TARS exactly.

**Replication slots — TARS has them off (`No`).** Without a slot, if a replica falls far enough
behind (or is down long enough) that the primary recycles the WAL it needs, the replica cannot
catch up via streaming and must be re-seeded from a base backup. Slots pin WAL retention on the
primary to guarantee a standby can always catch up — but at the risk of filling the primary's
disk if a standby is down for a long time and nobody notices. TARS's choice (no slots) trades
that primary-disk risk for reliance on `max_wal_size`/archiving to backstop replicas. CNPG
supports slots either way (`.spec.replicationSlots`); this build follows TARS and leaves them off.

**WAL level = logical.** Needed only if you plan logical replication/CDC consumers (e.g.
Debezium) downstream — it's a superset of `replica` level and costs a small amount of extra WAL
volume. TARS sets it for future logical-decoding consumers even though the documented HA/DR path
here is physical streaming + PITR, not logical replication.

**pgBackRest → Barman Cloud CNPG-I plugin.** The POC maps the TARS remote `repo2` role to a
MinIO-backed `ObjectStore`. WAL is archived continuously by the Barman Cloud plugin and weekly
base backups anchor the PITR timeline. The original TARS document also has a local `repo1`; this
POC does not yet implement a separate local backup repository and treats that as production
hardening/follow-up work.

**DR promotion is deliberate and fenced — by design, in both systems.** The TARS doc explicitly
calls out that DR promotion is manual and gated on confirming the former primary is fully
stopped, to prevent split-brain. CNPG's replica cluster works the same way: promotion is a
one-line manifest change (`spec.replica.enabled: false`), but it is a human-triggered action, not
automatic — you must be certain the original primary is down/fenced before promoting the DR
replica, or you will get two writable primaries diverging from the same WAL history.
