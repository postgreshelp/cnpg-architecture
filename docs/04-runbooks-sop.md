# 04 — Standard Operating Procedures (SOPs) / Runbooks

All commands assume you've completed the install steps in the root `README.md` and have
`KUBECONFIG` pointed at your Minikube cluster and the `kubectl cnpg` plugin installed.

---
## SOP-1: Health check (daily / on-call first response)

```bash
kubectl get cluster tarsdb-primary -n tars-db
kubectl cnpg status tarsdb-primary -n tars-db
kubectl get pods -n tars-db -l cnpg.io/cluster=tarsdb-primary -o wide
kubectl cnpg status tarsdb-dr -n tars-db-dr
```

Look for: `Status: Cluster in healthy state`, correct primary pod, replication lag near-zero,
and `Streaming` replicas shown as `streaming` (not `catching up` / not `unknown`).

**Sample healthy output (`kubectl cnpg status tarsdb-primary -n tars-db`):**
```
Cluster Summary
Name                     tars-db/tarsdb-primary
Primary instance:        tarsdb-primary-1
Status:                  Cluster in healthy state
Instances:               2
Ready instances:         2

Continuous Backup status (Barman Cloud Plugin)
Working WAL archiving:        OK
WALs waiting to be archived:  0
Last Failed WAL:              -

Streaming Replication status
Name              Write LSN  Flush LSN  Replay LSN  Write Lag  Flush Lag  Replay Lag  State      Sync State
tarsdb-primary-2  0/6A7A570  0/6A7A570  0/6A7A570   00:00:00   00:00:00   00:00:00    streaming  async

Instances status
Name              Replication role  Status  Node
tarsdb-primary-1  Primary           OK      minikube
tarsdb-primary-2  Standby (async)   OK      minikube
```
Red flags to escalate on: `Last Failed WAL` non-empty, any replica stuck in `catching up` for more
than a couple minutes, or `Ready instances` less than `Instances`. See
`docs/06-architecture-diagrams.md` §2 for the module diagram behind this output.

---
## SOP-2: Planned/automatic intra-site failover (primary pod lost)

CNPG handles this automatically — the operator detects the primary pod is unhealthy and promotes
the most caught-up replica within the same `Cluster`. Your job is to verify, not to trigger it:

```bash
kubectl get pods -n tars-db -l cnpg.io/cluster=tarsdb-primary -o wide
kubectl cnpg status tarsdb-primary -n tars-db     # confirm new primary elected
kubectl logs -n tars-db <new-primary-pod> | tail -50
```

To force a **manual** switchover (e.g. for planned maintenance on the current primary node):

```bash
kubectl cnpg promote tarsdb-primary <target-instance-pod-name> -n tars-db
```

---
## SOP-3: DR promotion (site failure — this is the fenced, manual step from TARS §4.1)

**Do not run this unless you have confirmed the primary site is fully stopped.** Promoting the DR
replica while the original primary can still accept writes creates a split-brain.

1. **Fence the original primary.** Confirm it is unreachable/stopped:
   ```bash
   kubectl get cluster tarsdb-primary -n tars-db      # if this errors/unreachable, site is down
   ```
   If the primary site is reachable but you are deliberately failing over, scale it down or
   isolate it first so it cannot accept writes:
   ```bash
   kubectl cnpg maintenance set tarsdb-primary -n tars-db --reusePVC=false   # optional, if reclaiming
   kubectl scale cluster tarsdb-primary -n tars-db --replicas=0   # last resort manual fence
   ```

2. **Confirm the DR replica is caught up as far as the object store allows:**
   ```bash
   kubectl cnpg status tarsdb-dr -n tars-db-dr
   ```

3. **Promote.** Edit the DR `Cluster` and flip it out of replica mode:
   ```bash
   kubectl patch cluster tarsdb-dr -n tars-db-dr --type merge \
     -p '{"spec":{"replica":{"enabled": false}}}'
   ```
   Watch it become primary:
   ```bash
   kubectl cnpg status tarsdb-dr -n tars-db-dr
   ```

4. **Re-point applications.** Update the connection matrix (see `docs/03-...` and your app
   Secrets) to `tarsdb-dr-rw.tars-db-dr.svc.cluster.local` until failback.

---
## SOP-4: Failback (return to original primary site, TARS §4.1)

Only after the original site's infrastructure is confirmed healthy again.

1. **Re-provision the old primary as a fresh replica cluster** pointed at the *new* primary's
   backup object store path — do NOT just restart the old pods in place:
   ```bash
   kubectl delete cluster tarsdb-primary -n tars-db      # old data directory is stale/diverged
   # edit manifests/dr/cluster-dr-as-standby-of-dr.yaml (template provided) to point at
   # whichever Cluster is currently primary, then:
   kubectl apply -f manifests/dr/cluster-dr-as-standby-of-dr.yaml -n tars-db
   ```
2. Wait for full resync:
   ```bash
   kubectl cnpg status tarsdb-primary -n tars-db
   ```
3. During a planned maintenance window, repeat the promotion procedure in SOP-3 in reverse to
   transfer primary role back, then re-point applications back to the original endpoints.

---
## SOP-5: Point-in-time recovery (restore from a logical mistake, not a site failure)

```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: tarsdb-pitr-restore
  namespace: tars-db
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:15.6
  storage:
    size: 500Gi
  bootstrap:
    recovery:
      source: primary-object-store
      recoveryTarget:
        targetTime: "2026-09-14 23:55:00+00"   # <-- set to just before the bad transaction
  externalClusters:
    - name: primary-object-store
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: tarsdb-primary-store
          serverName: tarsdb-primary
EOF
```

Validate the restored cluster in isolation (`psql` in, check the data), extract what you need,
then tear it down — this is a scratch recovery target, not a replacement for the primary.

---
## SOP-6: Backup verification (run weekly, don't just trust the schedule fired)

```bash
kubectl get scheduledbackup -n tars-db
kubectl get backup -n tars-db
kubectl cnpg status tarsdb-primary -n tars-db | grep -A5 "Continuous Backup status"
```

Confirm `firstRecoverabilityPoint` is moving forward and is within your 14-day retention target.

---
## SOP-7: Connection threshold incident (>34/50 in this POC's profile; TARS itself is >170/250 — see `manifests/monitoring/conn-monitor-cronjob.yaml`'s `MAX_CONNECTIONS`)

1. Check current count:
   ```bash
   kubectl exec -it -n tars-db tarsdb-primary-1 -- psql -U postgres -c \
     "select count(*) from pg_stat_activity;"
   ```
2. Identify offenders:
   ```bash
   kubectl exec -it -n tars-db tarsdb-primary-1 -- psql -U postgres -c \
     "select datname, usename, state, count(*) from pg_stat_activity group by 1,2,3 order by 4 desc;"
   ```
3. The idle-reaper (`scripts/monitor/conn_monitor.py`, deployed as a CronJob) should already be
   terminating anything `idle` for >5 minutes — check its logs:
   ```bash
   kubectl logs -n tars-common -l app=conn-monitor --tail=100
   ```
4. If a specific app is misbehaving (opening connections without closing), throttle it at the
   Pooler (`default_pool_size` / `max_client_conn` in `manifests/pooler/pooler-pgbouncer.yaml`)
   as an immediate mitigation, then fix the app's connection handling.
