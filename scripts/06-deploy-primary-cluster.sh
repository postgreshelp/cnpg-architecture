#!/usr/bin/env bash
# 06-deploy-primary-cluster.sh — the primary HA Cluster (instances:2, matches TARS primary+async replica)
set -euo pipefail

kubectl apply -f ../manifests/secrets/minio-creds-secret.yaml -n tars-db
kubectl apply -f ../manifests/secrets/postgres-superuser-secret.yaml -n tars-db
kubectl apply -f ../manifests/secrets/postgres-app-secret.yaml -n tars-db
kubectl apply -f ../manifests/backup/objectstore-primary.yaml
kubectl apply -f ../manifests/cluster/cluster-primary.yaml

echo "== Waiting for the primary Cluster to reach a healthy state (can take a few minutes) =="
kubectl wait --for=condition=Ready cluster/tarsdb-primary -n tars-db --timeout=600s || true
kubectl cnpg status tarsdb-primary -n tars-db

# The DR replica cluster needs at least one completed base backup before it can bootstrap.
# The production schedule is weekly, but a POC must seed the repository immediately.
BACKUP_NAME="tarsdb-initial-$(date +%Y%m%d%H%M%S)"
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${BACKUP_NAME}
  namespace: tars-db
spec:
  cluster:
    name: tarsdb-primary
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF

echo "== Waiting for initial Barman Cloud backup: ${BACKUP_NAME} =="
for i in $(seq 1 120); do
  PHASE="$(kubectl get backup "${BACKUP_NAME}" -n tars-db -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$PHASE" in
    completed) echo "Initial backup completed: ${BACKUP_NAME}"; break ;;
    failed) echo "Initial backup failed: ${BACKUP_NAME}"; kubectl describe backup "${BACKUP_NAME}" -n tars-db; exit 1 ;;
  esac
  if [ "$i" -eq 120 ]; then
    echo "Timed out waiting for initial backup ${BACKUP_NAME}"
    kubectl describe backup "${BACKUP_NAME}" -n tars-db
    exit 1
  fi
  sleep 5
done
