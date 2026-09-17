#!/usr/bin/env bash
# 08-deploy-dr-replica-cluster.sh — simulated DR site: 2nd Cluster, 2nd namespace, same Minikube
set -euo pipefail

kubectl apply -f ../manifests/secrets/minio-creds-secret.yaml -n tars-db-dr
kubectl apply -f ../manifests/backup/objectstore-primary-dr.yaml
kubectl apply -f ../manifests/dr/cluster-dr-replica.yaml

echo "== Waiting for the DR replica cluster to bootstrap from the object store =="
kubectl wait --for=condition=Ready cluster/tarsdb-dr -n tars-db-dr --timeout=600s || true
kubectl cnpg status tarsdb-dr -n tars-db-dr
echo "DR cluster is a READ-ONLY replica cluster. Promote only via SOP-3 in docs/04-runbooks-sop.md."
