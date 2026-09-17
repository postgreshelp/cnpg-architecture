#!/usr/bin/env bash
# 07-deploy-pooler.sh — pgBouncer via the CNPG Pooler CRD
set -euo pipefail

kubectl apply -f ../manifests/pooler/pooler-pgbouncer.yaml

# The CNPG operator materializes the Pooler's Deployment asynchronously — right after apply it
# may not exist yet, and "kubectl rollout status" errors immediately (NotFound) rather than
# waiting for the resource to appear, unlike "kubectl wait".
echo "== Waiting for the operator to create the Pooler's Deployment =="
for i in $(seq 1 30); do
  kubectl get deployment -n tars-db tarsdb-pgbouncer &>/dev/null && break
  sleep 2
done

kubectl rollout status deployment -n tars-db tarsdb-pgbouncer --timeout=180s
kubectl get svc -n tars-db | grep pgbouncer
