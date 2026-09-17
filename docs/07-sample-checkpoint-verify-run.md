# 07 — Sample Checkpoint Deploy + Verify Run

This is a real `./one-click-deploy.sh --checkpoint` run followed by the standalone verify commands
from the README, captured against an already-provisioned cluster (most steps show "already
installed, skipping" since this was a re-run, not a fresh install). Each block is annotated with a
one-liner on what it proves.

## Checkpoint deploy

```
[08:18:18] Starting deploy (checkpoint mode: true). Full log: /root/tars-cnpg-centos9-8gb-poc/one-click-deploy.log
```
`--checkpoint` pauses after every step and prints a status snapshot so you can eyeball each phase
before moving on, instead of only finding out something's wrong at the end.

### STEP 1/12 — OS prerequisites
```
Mem:           8.6Gi       3.2Gi       691Mi       242Mi       5.3Gi       5.5Gi
/dev/mapper/cs-root   42G   35G  6.7G  85% /
```
Confirms the host still has enough free memory and disk headroom for minikube + the PostgreSQL
pods before doing anything else.

### STEP 2/12 — Docker
```
Active: active (running) since Wed 2026-09-16 19:39:17 IST; 12h ago
```
Docker was already installed and its systemd unit is healthy, so the script skips reinstalling it.

### STEP 3/12 — Minikube + kubectl + namespaces
```
minikube   Ready    control-plane   12h   v1.37.0
cert-manager, cnpg-system, minio, tars-common, tars-db, tars-db-dr   Active
```
The cluster is up and all namespaces this POC depends on already exist.

### STEP 4/12 — CloudNativePG operator
```
barman-cloud-9bf6d48b4-pphrp               1/1     Running
cnpg-controller-manager-66b5b6b645-xzdkl   1/1     Running
```
The CNPG operator and the Barman Cloud CNPG-I plugin sidecar are both running, so backup/restore
plugin calls will work.

### STEP 5/12 — Secrets
```
-rw------- 1 root root 526 Sep 17 08:18 /root/tars-cnpg-centos9-8gb-poc/credentials.txt
```
Fresh random credentials were generated with `0600` permissions (owner-only read/write).

### STEP 6/12 — MinIO object store
```
pod/minio-84b848467c-4ssnf   1/1     Running   0          15s
```
MinIO restarted clean (age 15s) and is serving on 9000/9001 — this is the S3-compatible target for
WAL archiving and backups.

### STEP 7/12 — postgresbackup bucket
Bucket creation is logged to `one-click-deploy.log` rather than the checkpoint screen, since `mc
ls` output is verbose.

### STEP 8/12 — Primary HA cluster
```
Status:                  Cluster in healthy state
Instances:               2   Ready instances:               2
Working WAL archiving:          OK
WALs waiting to be archived:    0
tarsdb-primary-2  ...  streaming  async       0
```
Both primary and standby are `Ready`, WAL archiving to the object store has no backlog, and
streaming replication is caught up (all LSN columns match, zero lag).

### STEP 9/12 — pgBouncer Pooler
```
pod/tarsdb-pgbouncer-5d7fb85756-tt5gp   1/1     Running   0          12h
```
The connection pooler in front of the primary has been up and stable for 12h.

### STEP 10/12 — DR replica cluster
```
Status:                  Cluster in healthy state
Instances:               1   Ready instances:               1
```
The DR cluster is bootstrapped from the object store (not streaming from the primary) and is
healthy as a designated-primary replica cluster.

### STEP 11/12 — Connection monitor
```
NAME           SCHEDULE       SUSPEND   ACTIVE   LAST SCHEDULE   AGE
conn-monitor   */10 * * * *   False     0        9m41s           12h
```
The idle-connection-reaper CronJob is enabled (`SUSPEND: False`) and last fired 9m41s ago, in line
with its 10-minute schedule.

### STEP 12/12 — skipped
Test-data loading only runs when `--with-test-data` is passed; this run didn't request it.

```
[08:19:42] DONE.
```
All 12 steps completed with no failures.

## Standalone verify commands

```bash
kubectl cnpg status tarsdb-primary -n tars-db
```
Repeating this command mid-run shows `Primary promotion time` age climbing (12h17m24s →
12h17m29s → 12h17m33s) with everything else unchanged — confirming the primary hasn't failed over
and the cluster is idling in a stable healthy state, not stuck mid-reconcile.

```bash
kubectl cnpg status tarsdb-dr -n tars-db-dr
```
Same healthy/ready result as the checkpoint step — the DR replica cluster is independently
verified after the full deploy finished, not just mid-rollout.

```bash
kubectl get pooler -n tars-db
```
```
NAME               AGE   CLUSTER          TYPE   PHASE
tarsdb-pgbouncer   12h   tarsdb-primary   rw     active
```
`PHASE: active` confirms pgBouncer is actually routing traffic, not just that the pod is running.

```bash
kubectl get cronjob -n tars-common
```
```
NAME           SCHEDULE       TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
conn-monitor   */10 * * * *   <none>     False     0        26s             12h
```
`LAST SCHEDULE: 26s` shows the CronJob fired again shortly after the checkpoint run finished,
confirming it's still on schedule rather than stalled.

## What "all healthy" looks like end to end

Primary + standby both `Ready`, WAL archiving `OK` with zero backlog, DR cluster `healthy`, pooler
`active`, and `conn-monitor` firing on its 10-minute schedule — matching the "Verify the
deployment" checklist in the [README](../README.md#verify-the-deployment-sample-output-from-a-real-run).
