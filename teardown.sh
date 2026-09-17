#!/usr/bin/env bash
# teardown.sh — tears everything down (clusters, pooler, MinIO, monitor, operator, namespaces).
# Does NOT touch Docker/Minikube/kubectl themselves or delete generated credentials.txt.
# Use --full to also stop/delete the Minikube VM itself.
set -euo pipefail

FULL=false
[ "${1:-}" = "--full" ] && FULL=true

read -r -p "This deletes tarsdb-primary, tarsdb-dr, the pooler, MinIO, and the conn-monitor CronJob. Continue? [y/N] " CONFIRM
[ "${CONFIRM,,}" = "y" ] || { echo "Aborted."; exit 0; }

kubectl delete objectstore tarsdb-primary-store -n tars-db --ignore-not-found
kubectl delete objectstore tarsdb-primary-store -n tars-db-dr --ignore-not-found
kubectl delete cluster tarsdb-primary -n tars-db --ignore-not-found
kubectl delete cluster tarsdb-dr -n tars-db-dr --ignore-not-found
kubectl delete pooler tarsdb-pgbouncer -n tars-db --ignore-not-found
kubectl delete scheduledbackup tarsdb-weekly-full -n tars-db --ignore-not-found
kubectl delete cronjob conn-monitor -n tars-common --ignore-not-found
kubectl delete deployment minio -n minio --ignore-not-found
kubectl delete pvc minio-data -n minio --ignore-not-found

if [ "$FULL" = true ]; then
  echo "Stopping and deleting the Minikube VM..."
  minikube delete
fi

echo "Teardown complete."
