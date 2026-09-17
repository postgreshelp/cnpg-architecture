#!/usr/bin/env bash
# one-click-deploy.sh — install: CentOS 9 -> working CNPG HA + DR + pooler + monitoring stack.
# Run as root on a fresh CentOS 9 host.
#
# Usage:
#   ./one-click-deploy.sh                    # full unattended install
#   ./one-click-deploy.sh --checkpoint       # pause after each phase, show status, wait for Enter
#   ./one-click-deploy.sh --with-test-data   # also loads schema + 100k Faker rows at the end
#   ./one-click-deploy.sh --with-edb         # also prompts for EDB registry creds + wires imagePullSecrets
#   ./one-click-deploy.sh --skip-os-prep     # skip steps 1-2 (already-provisioned host/rerun)
#   (flags can be combined, e.g. --checkpoint --with-test-data)
#
# Idempotent: safe to re-run after a partial failure — every step either checks for an
# existing resource first or uses 'kubectl apply' (which is itself idempotent).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$REPO_ROOT/one-click-deploy.log"
WITH_TEST_DATA=false
SKIP_OS_PREP=false
WITH_EDB=false
CHECKPOINT=false

for arg in "$@"; do
  case "$arg" in
    --with-test-data) WITH_TEST_DATA=true ;;
    --skip-os-prep)   SKIP_OS_PREP=true ;;
    --with-edb)       WITH_EDB=true ;;
    --checkpoint)     CHECKPOINT=true ;;
    *) echo "Unknown flag: $arg" && exit 1 ;;
  esac
done

log()  { echo -e "\n\033[1;36m[$(date +%H:%M:%S)] $*\033[0m" | tee -a "$LOG_FILE"; }
fail() { echo -e "\033[1;31m[FAILED] $*\033[0m" | tee -a "$LOG_FILE"; exit 1; }
retry() {
  # retry <max_attempts> <sleep_seconds> <command...>
  local max="$1" sleep_s="$2"; shift 2
  local n=1
  until "$@"; do
    if [ "$n" -ge "$max" ]; then fail "command failed after $max attempts: $*"; fi
    echo "  retry $n/$max in ${sleep_s}s: $*"
    sleep "$sleep_s"
    n=$((n + 1))
  done
}
# checkpoint <phase label> <status command...>
# Runs the given read-only status command, prints its output (not just to the log — to the
# terminal, since this is the whole point), then pauses for Enter. No-op unless --checkpoint.
checkpoint() {
  local label="$1"; shift
  [ "$CHECKPOINT" = true ] || return 0
  echo -e "\n\033[1;33m--- checkpoint: ${label} ---\033[0m"
  "$@" || echo "(status command returned non-zero — review before continuing)"
  echo -e "\033[1;33m----------------------------\033[0m"
  read -r -p "Press Enter to continue to the next phase (Ctrl+C to stop here)... " _
}

if [ "$EUID" -ne 0 ]; then fail "run as root (sudo ./one-click-deploy.sh)"; fi

: > "$LOG_FILE"
log "Starting deploy (checkpoint mode: $CHECKPOINT). Full log: $LOG_FILE"

cd "$REPO_ROOT/scripts"

if [ "$SKIP_OS_PREP" = false ]; then
  log "STEP 1/12 — OS prerequisites"
  ./00-prereqs-centos9.sh >> "$LOG_FILE" 2>&1 || fail "00-prereqs-centos9.sh"
  checkpoint "OS prerequisites" bash -c "free -h; df -h /"

  log "STEP 2/12 — Docker"
  if ! command -v docker &>/dev/null; then
    ./01-install-docker.sh >> "$LOG_FILE" 2>&1 || fail "01-install-docker.sh"
  else
    echo "  docker already installed, skipping" | tee -a "$LOG_FILE"
  fi
  checkpoint "Docker" systemctl status docker --no-pager -l
else
  log "STEP 1-2/13 — skipped (--skip-os-prep)"
fi

log "STEP 3/12 — Minikube + kubectl + namespaces"
if ! command -v kubectl &>/dev/null || ! command -v minikube &>/dev/null; then
  ./02-install-minikube-kubectl.sh >> "$LOG_FILE" 2>&1 || fail "02-install-minikube-kubectl.sh"
else
  echo "  kubectl/minikube already present; ensuring cluster is up + namespaces exist" | tee -a "$LOG_FILE"
  if ! minikube status &>/dev/null; then
    MINIKUBE_CPUS="${MINIKUBE_CPUS:-4}"
    MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-5g}"
    MINIKUBE_DISK="${MINIKUBE_DISK:-40g}"
    minikube start --driver=docker --cpus="$MINIKUBE_CPUS" --memory="$MINIKUBE_MEMORY" --disk-size="$MINIKUBE_DISK" --force >> "$LOG_FILE" 2>&1
  fi
  for ns in tars-db tars-db-dr minio tars-common; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >> "$LOG_FILE" 2>&1
  done
fi
checkpoint "Minikube + namespaces" bash -c "kubectl get nodes; kubectl get ns"

log "STEP 4/12 — CloudNativePG operator"
if ! kubectl get deployment -n cnpg-system cnpg-controller-manager &>/dev/null; then
  ./03-install-cnpg-operator.sh >> "$LOG_FILE" 2>&1 || fail "03-install-cnpg-operator.sh"
else
  echo "  CNPG operator already installed, skipping" | tee -a "$LOG_FILE"
fi
checkpoint "CNPG operator" kubectl get pods -n cnpg-system

if [ "$WITH_EDB" = true ]; then
  log "STEP 4b/13 — EDB registry credentials (interactive — this cannot be automated, see note below)"
  echo "  Enter the credentials from your EDB account portal when prompted."
  ./setup-edb-registry.sh
  echo "  Secret created. Remember: you still need to manually edit imageName + uncomment"
  echo "  imagePullSecrets in manifests/cluster/cluster-primary.yaml and manifests/dr/cluster-dr-replica.yaml"
  echo "  BEFORE step 8/10 run below, if you want the primary/DR clusters to use an EDB image"
  echo "  from this very run. Otherwise re-apply those manifests afterwards to switch images."
  checkpoint "EDB registry secret" bash -c "kubectl get secret edb-registry-creds -n tars-db; kubectl get secret edb-registry-creds -n tars-db-dr"
fi

log "STEP 5/12 — Generating strong random secrets (see ../credentials.txt afterwards)"
./generate-secrets.sh >> "$LOG_FILE" 2>&1 || fail "generate-secrets.sh"
checkpoint "Secrets generated" bash -c "ls -la '$REPO_ROOT/credentials.txt'"

log "STEP 6/12 — MinIO object store"
./04-deploy-minio.sh >> "$LOG_FILE" 2>&1 || fail "04-deploy-minio.sh"
checkpoint "MinIO" kubectl get pods,svc -n minio

log "STEP 7/12 — Creating the postgresbackup bucket"
retry 5 10 bash -c "cd '$REPO_ROOT/scripts' && ./05-create-minio-buckets.sh >> '$LOG_FILE' 2>&1"
checkpoint "MinIO bucket" bash -c "echo 'bucket creation logged above — see $LOG_FILE for mc ls output'"

log "STEP 8/12 — Primary HA Cluster (this can take several minutes on first run)"
./06-deploy-primary-cluster.sh >> "$LOG_FILE" 2>&1 || fail "06-deploy-primary-cluster.sh"
kubectl wait --for=condition=Ready cluster/tarsdb-primary -n tars-db --timeout=900s >> "$LOG_FILE" 2>&1 \
  || fail "tarsdb-primary did not become Ready in time — check: kubectl cnpg status tarsdb-primary -n tars-db"
checkpoint "Primary HA cluster" kubectl cnpg status tarsdb-primary -n tars-db

log "STEP 9/12 — pgBouncer Pooler"
./07-deploy-pooler.sh >> "$LOG_FILE" 2>&1 || fail "07-deploy-pooler.sh"
checkpoint "Pooler" kubectl get pooler,pods -n tars-db -l cnpg.io/poolerName=tarsdb-pgbouncer

log "STEP 10/12 — DR replica cluster"
./08-deploy-dr-replica-cluster.sh >> "$LOG_FILE" 2>&1 || fail "08-deploy-dr-replica-cluster.sh"
kubectl wait --for=condition=Ready cluster/tarsdb-dr -n tars-db-dr --timeout=900s >> "$LOG_FILE" 2>&1 \
  || fail "tarsdb-dr did not become Ready in time — check: kubectl cnpg status tarsdb-dr -n tars-db-dr"
checkpoint "DR replica cluster" kubectl cnpg status tarsdb-dr -n tars-db-dr

log "STEP 11/12 — Connection monitor (threshold alert + idle reaper CronJob)"
kubectl create configmap conn-monitor-script \
  --from-file=conn_monitor.py=monitor/conn_monitor.py \
  -n tars-common --dry-run=client -o yaml | kubectl apply -f - >> "$LOG_FILE" 2>&1
kubectl apply -f "$REPO_ROOT/manifests/monitoring/conn-monitor-secret.yaml" >> "$LOG_FILE" 2>&1
kubectl apply -f "$REPO_ROOT/manifests/monitoring/conn-monitor-cronjob.yaml" >> "$LOG_FILE" 2>&1
checkpoint "Connection monitor" kubectl get cronjob -n tars-common

if [ "$WITH_TEST_DATA" = true ]; then
  log "STEP 12/12 — Loading schema + 100k test rows (this takes a few minutes)"
  ./09-load-test-data.sh >> "$LOG_FILE" 2>&1 || fail "09-load-test-data.sh"
  checkpoint "Test data loaded" kubectl exec -n tars-db tarsdb-primary-1 -- psql -U postgres -d tars -c "select count(*) from books;"
else
  log "STEP 12/12 — skipped (pass --with-test-data to load schema + 100k rows)"
fi

log "DONE."
echo
echo "================================================================"
echo " Deployment complete."
echo "   Credentials : $REPO_ROOT/credentials.txt"
echo "   Full log    : $LOG_FILE"
echo
echo " Verify:"
echo "   kubectl cnpg status tarsdb-primary -n tars-db"
echo "   kubectl cnpg status tarsdb-dr -n tars-db-dr"
echo "   kubectl get pooler -n tars-db"
echo "   kubectl get cronjob -n tars-common"
echo
echo " Day-2 operations (failover, DR promotion, failback, PITR, incidents):"
echo "   docs/04-runbooks-sop.md"
echo "================================================================"
